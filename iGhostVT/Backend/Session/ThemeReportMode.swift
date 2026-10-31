//
//  ThemeReportMode.swift
//  iGhostVT
//

import Foundation

/// Whether the program on a terminal asked to hear about light/dark changes:
/// DEC private mode 2031, which Claude Code and Neovim set as they start.
/// The terminal answers a change with `CSI ? 997 ; 1|2 n`, and Claude Code
/// then asks for the background colour again (OSC 11).
///
/// Ghostty reports only when its configuration changes, and a tab's changes
/// as it opens happen before an attach's output arrives — before that output
/// turns the mode on. A program that was already running on the session
/// then never hears this device's appearance, nor one that changed while
/// the link was down. So each tab follows the mode across what it receives
/// (`TerminalSessionStore`) and, once an attach's output is in, sends the
/// report itself. A host's rebuilt replay sets the mode again in its
/// preamble (`TerminalReplayState`); the raw buffer of a host before 1.6.22
/// may have lost the set to its trim, and that program stays as it was.
///
/// The scanner keeps its place across chunks, so a sequence cut between two
/// reads is still seen. It reads nothing else.
struct ThemeReportMode {
    private(set) var isEnabled = false

    private enum Phase {
        case ground
        case escape
        case controlSequence
        case privateParameters
    }

    private var phase = Phase.ground
    private var parameter = 0
    private var namesMode = false

    static let mode = 2031

    /// What a terminal sends the program for a change: 1 dark, 2 light.
    static func report(isDark: Bool) -> Data {
        Data("\u{1B}[?997;\(isDark ? 1 : 2)n".utf8)
    }

    /// A replay rebuilds the terminal from a clean slate, and a fresh
    /// session starts with nothing set.
    mutating func reset() {
        self = ThemeReportMode()
    }

    mutating func feed(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var index = 0
            let count = buffer.count
            while index < count {
                if phase == .ground {
                    // Nearly all output is text: skip to the next escape.
                    guard let found = memchr(base + index, 0x1B, count - index) else { return }
                    index = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + 1
                    phase = .escape
                    continue
                }
                step(base[index])
                index += 1
            }
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch phase {
        case .ground:
            if byte == 0x1B { phase = .escape }
        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                phase = .controlSequence
            case UInt8(ascii: "c"):
                // RIS: a full reset turns every mode off.
                isEnabled = false
                phase = .ground
            case 0x1B:
                break
            default:
                phase = .ground
            }
        case .controlSequence:
            if byte == UInt8(ascii: "?") {
                phase = .privateParameters
                parameter = 0
                namesMode = false
            } else {
                phase = byte == 0x1B ? .escape : .ground
            }
        case .privateParameters:
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                // Capped, never overflowed: the bytes are the program's.
                if parameter < 100_000 {
                    parameter = parameter * 10 + Int(byte - UInt8(ascii: "0"))
                }
            case UInt8(ascii: ";"):
                namesMode = namesMode || parameter == Self.mode
                parameter = 0
            case UInt8(ascii: "h"), UInt8(ascii: "l"):
                if namesMode || parameter == Self.mode {
                    isEnabled = byte == UInt8(ascii: "h")
                }
                phase = .ground
            case 0x1B:
                phase = .escape
            default:
                // Another final or an intermediate (`$p` asks, it sets nothing).
                phase = .ground
            }
        }
    }
}

/// One tab's `ThemeReportMode`, fed on whichever transport queue carries
/// the tab's link and kept across links, since output that resumes where a
/// link left off sets nothing again.
final class ThemeReportTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var mode = ThemeReportMode()

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mode.isEnabled
    }

    func feed(_ data: Data, replacingState: Bool = false) {
        lock.lock()
        if replacingState {
            mode.reset()
        }
        mode.feed(data)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        mode.reset()
        lock.unlock()
    }
}
