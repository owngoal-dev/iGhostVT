//
//  TabFontSize.swift
//  iGhostVT
//

import Combine
import Foundation
import GhosttyTerminal

/// A tab's text size: Settings ▸ Text Size (`TerminalFontSize.base`) moved
/// by the tab's own offset (`TabAttributes.fontOffset`).
///
/// Every way of zooming is an offset: ⌘+ / ⌘− and the tab's menu step it
/// here, Actual Size clears it, and a zoom the surface makes by itself — a
/// pinch, or Ghostty's own key binding when the app's shortcut is off — is
/// read back off the size the surface reports. Settings is never written
/// from a tab; a change there moves every open tab, offsets kept.
///
/// Sizes reach the surface only through `set_font_size`. The surface
/// option's `fontSize` is part of a surface's identity: changed on a
/// mounted view it rebuilds the surface, grid and scrollback gone. So the
/// option holds the size the tab was made at, and a surface made later
/// from it (SwiftUI rebuilding the representable) is brought to the tab's
/// size when it first reports.
@MainActor
final class TabFontSize {
    private let terminal: TerminalViewState
    private let attributes: TabAttributes
    /// The size last asked of the surface, or the one it reported by itself.
    private var requested: Float
    /// The surface the last report came from. A report from another one is
    /// a surface just made at the option's size, not a zoom.
    private weak var reportingSurface: TerminalSurface?
    /// Sizes asked of the surface whose report has not come back. Reports
    /// are published a turn late and coalesced, so a Text Size stepper
    /// tapped twice can hear the first size after asking for the second:
    /// that one is ours, not a zoom.
    private var asked: Set<Float> = []
    private var observations: Set<AnyCancellable> = []

    init(terminal: TerminalViewState, attributes: TabAttributes) {
        self.terminal = terminal
        self.attributes = attributes
        requested = TerminalFontSize.size(offset: attributes.fontOffset)
        terminal.$fontSize
            .sink { [weak self] reported in
                self?.surfaceReported(reported)
            }
            .store(in: &observations)
        // Every default written posts this, on the writer's thread; the
        // base is read there and only a change reaches the main queue.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in TerminalFontSize.base }
            .prepend(TerminalFontSize.base)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.baseChanged() }
            }
            .store(in: &observations)
    }

    /// The size a new surface for this tab starts at.
    var initialSize: Float {
        requested
    }

    func canStep(by delta: Int) -> Bool {
        let size = Int(currentSize.rounded()) + delta
        return TerminalFontSize.range.contains(size)
    }

    /// ⌘+ / ⌘− and the tab's menu: a point bigger or smaller.
    func step(by delta: Int) {
        guard canStep(by: delta) else { return }
        setOffset(Int(currentSize.rounded()) + delta - TerminalFontSize.base)
    }

    /// Actual Size: back to Settings ▸ Text Size.
    func reset() {
        setOffset(0)
    }

    /// The offset the session kept, taken on reattach.
    func adopt(offset: Int) {
        setOffset(offset)
    }

    /// What the surface shows now, or will once it is up. The view's own
    /// size, not the state's published copy, which trails it by a turn.
    private var currentSize: Float {
        terminal.attachedPlatformView?.fontSize ?? requested
    }

    private func setOffset(_ offset: Int) {
        if attributes.fontOffset != offset {
            attributes.fontOffset = offset
        }
        apply(TerminalFontSize.size(offset: offset))
    }

    private func baseChanged() {
        apply(TerminalFontSize.size(offset: attributes.fontOffset))
        // The generated config's `font-size` is the base too: Ghostty's own
        // `reset_font_size` (⌘0 with the app's shortcut off) returns there.
        // A surface already sized holds its size through the reload.
        terminal.controller.setTerminalConfiguration(GhosttyAppConfiguration.terminal)
    }

    private func apply(_ size: Float) {
        requested = size
        // No surface yet: its first report brings it to `requested`.
        guard let current = terminal.attachedPlatformView?.fontSize, current != size else { return }
        ask(size)
    }

    private func ask(_ size: Float) {
        if terminal.performBindingAction("set_font_size:\(size)") {
            asked.insert(size)
        }
    }

    private func surfaceReported(_ reported: Float?) {
        guard let reported else { return }
        let surface = terminal.surface
        guard surface === reportingSurface else {
            reportingSurface = surface
            asked.removeAll()
            if reported != requested {
                ask(requested)
            }
            return
        }
        guard reported != requested else {
            asked.removeAll()
            return
        }
        guard !asked.contains(reported) else { return }
        asked.removeAll()
        requested = reported
        let offset = Int(reported.rounded()) - TerminalFontSize.base
        if attributes.fontOffset != offset {
            attributes.fontOffset = offset
        }
    }
}
