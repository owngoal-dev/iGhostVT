//
//  TerminalDirectory.swift
//  iGhostVT
//

import Foundation

/// A directory a session sits in, in the two spellings the product needs.
///
/// They are the same string in every layout but roothide, where the
/// bootstrap lives in a randomly named jbroot: the kernel calls a shell's
/// directory `/var/containers/Bundle/Application/<uuid>/usr/src`, the shell
/// itself calls it `/usr/src`, and only the first is a path the daemon can
/// `chdir` to. So one is carried to be handed back and the other to be read.
/// The daemon sends the second only when it differs
/// (`iGhostVTWireKey.displayDirectory`).
struct TerminalDirectory: Hashable, Codable, Sendable {
    /// Exactly as the daemon reported it, and the only spelling
    /// `openSession` takes back (`startDirectory`). Never shown.
    var path: String
    /// The same directory as the bootstrap's own programs print it — what
    /// the user typed to get here, and what a menu row says.
    var display: String

    init(path: String, display: String? = nil) {
        self.path = path
        self.display = display.flatMap { $0.isEmpty ? nil : $0 } ?? path
    }

    /// What a row calls this directory: the display spelling with the
    /// session user's home collapsed to `~`.
    var label: String {
        Self.abbreviate(display)
    }

    /// A path as a person should read it. OSC 7 arrives as a `file://` URL
    /// from some shells and a bare path from others; either way the shell's
    /// home is noise, so it collapses to `~`.
    ///
    /// Shared with the Live Activity, which has only the shell's own OSC 7
    /// report to go on.
    static func abbreviate(_ reported: String?) -> String {
        guard var path = reported, !path.isEmpty else { return "" }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        for home in homeDirectories where path.hasPrefix(home) {
            let rest = path.dropFirst(home.count)
            if rest.isEmpty {
                return "~"
            }
            // Only at a boundary: `/var/mobilesomething` is not in the home.
            if rest.hasPrefix("/") {
                return "~" + rest
            }
        }
        return path
    }

    /// The homes worth collapsing. The device's session user is `mobile`,
    /// under either spelling of its path; the Mac's is whoever is logged
    /// in, and the Catalyst app is unsandboxed, so it can simply ask.
    private static let homeDirectories: [String] = {
        #if targetEnvironment(macCatalyst)
            [NSHomeDirectory()]
        #else
            ["/private/var/mobile", "/var/mobile"]
        #endif
    }()
}
