//
//  TabContextMenu.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI
import UIKit

/// The context menu shared by every presentation of a tab — the strip's
/// chips, the title capsule, the sidebar rows, and the switcher cards.
///
/// Copy and export read the viewport ("the page", see `TabPageExport`):
/// what the terminal is showing right now, trailing padding stripped. Copy
/// as Image prefers the surface's real pixels and falls back to drawing the
/// text for a tab whose surface is not currently rendering.
///
/// It observes the tab's `TabAttributes` and nothing else. The tab itself
/// republishes on every retitle, and UIKit rebuilds a menu that is open
/// whenever SwiftUI re-evaluates its content — so a menu that watched the
/// tab flickered grey and lost taps for as long as the terminal printed.
/// Everything else it shows is fixed, and copy and export read the page
/// when they are tapped. The views that host it follow the same rule: the
/// one carrying `.contextMenu` observes nothing that output changes, and
/// its title and badge are child views that observe for themselves.
struct TabContextMenu: View {
    let tab: TerminalTab
    let tabManager: TabManager
    let window: UIWindow?
    @ObservedObject private var attributes: TabAttributes

    init(tab: TerminalTab, tabManager: TabManager, window: UIWindow?) {
        self.tab = tab
        self.tabManager = tabManager
        self.window = window
        attributes = tab.attributes
    }

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("TabContextMenu")
        #endif
        Button(action: copyText) {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        Button(action: copyImage) {
            Label("Copy as Image", systemImage: "photo.on.rectangle")
        }
        Button(action: exportText) {
            Label("Export Text…", systemImage: "square.and.arrow.up")
        }
        Divider()
        lockControls
        Divider()
        if TabWindowMove.isAvailable {
            TabMoveButton(tab: tab, tabManager: tabManager)
        }
        Button(role: .destructive, action: { tabManager.requestClose(tab, from: .contextMenu) }) {
            Label("Close Tab", systemImage: "trash")
        }
    }

    /// Checkmarked toggles where the menu system renders them (iOS 16);
    /// state-named buttons before that, because a pre-16 menu shows no
    /// checkmark and a static "Lock Tab" would read as unlocked forever.
    /// The two are one choice: `TabAttributes.lock` holds at most one of
    /// them, so turning on the other lock switches, and turning off the one
    /// that is on clears it.
    @ViewBuilder
    private var lockControls: some View {
        lockControl($attributes.isLocked, lock: "Lock Tab", lockImage: "lock", unlock: "Unlock Tab", unlockImage: "lock.open")
        // Not on the Mac: there is no software keyboard to lock, and the
        // empty-inputView trick deliberately lets hardware keys through —
        // which is every key a Mac has, so the lock read as broken there.
        #if !targetEnvironment(macCatalyst)
            lockControl(
                $attributes.isKeyboardLocked,
                lock: "Lock Keyboard",
                lockImage: "keyboard",
                unlock: "Unlock Keyboard",
                unlockImage: "keyboard",
            )
        #endif
    }

    @ViewBuilder
    private func lockControl(
        _ isLocked: Binding<Bool>,
        lock: LocalizedStringKey,
        lockImage: String,
        unlock: LocalizedStringKey,
        unlockImage: String,
    ) -> some View {
        if #available(iOS 16.0, *) {
            Toggle(isOn: isLocked) {
                Label(lock, systemImage: lockImage)
            }
        } else if isLocked.wrappedValue {
            Button(action: { isLocked.wrappedValue = false }) {
                Label(unlock, systemImage: unlockImage)
            }
        } else {
            Button(action: { isLocked.wrappedValue = true }) {
                Label(lock, systemImage: lockImage)
            }
        }
    }

    // MARK: - The page as text

    private var pageText: String {
        TabPageExport.pageText(of: tab)
    }

    private func copyText() {
        UIPasteboard.general.string = pageText
        CopiedIndicator.present(in: window)
    }

    // MARK: - The page as an image

    private func copyImage() {
        guard let image = surfaceImage() ?? renderedTextImage() else { return }
        UIPasteboard.general.image = image
        CopiedIndicator.present(in: window)
    }

    /// The surface's real pixels — only while it is rendering. A background
    /// tab's surface is paused (`isSurfaceVisible == false`) and its last
    /// frame cannot be trusted to exist; the text fallback covers it.
    private func surfaceImage() -> UIImage? {
        guard tab.terminal.isSurfaceVisible else { return nil }
        return tab.terminal.attachedPlatformView?.snapshotImage()
    }

    /// The page text drawn in a monospaced face on the system background —
    /// deterministic, works for any tab in any presentation context.
    private func renderedTextImage() -> UIImage? {
        let text = pageText
        guard !text.isEmpty else { return nil }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.label,
        ]
        let padding: CGFloat = 16
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 4096, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: textAttributes,
            context: nil,
        )
        let size = CGSize(
            width: ceil(bounds.width) + padding * 2,
            height: ceil(bounds.height) + padding * 2,
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(
                at: CGPoint(x: padding, y: padding),
                withAttributes: textAttributes,
            )
        }
    }

    // MARK: - Export

    private func exportText() {
        TabPageExport.exportText(of: tab, in: window)
    }
}

/// Move to New Window (`TabWindowMove`). Its own view because it is the
/// one item that changes while the menu could be open: it appears once the
/// tab has a session and the window a second tab, and it observes those
/// two things alone — the session id on `TabAttributes`, and the tab list,
/// which changes when a tab comes or goes, never with output.
private struct TabMoveButton: View {
    let tab: TerminalTab
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var attributes: TabAttributes

    init(tab: TerminalTab, tabManager: TabManager) {
        self.tab = tab
        self.tabManager = tabManager
        attributes = tab.attributes
    }

    /// Left out, not greyed, when it cannot act: a disabled row for the
    /// window's only tab is an item the user can never use from here.
    var body: some View {
        if attributes.sessionID != nil, tabManager.tabs.count >= 2 {
            Button(action: { TabWindowMove.moveToNewWindow(tab, from: tabManager) }) {
                Label("Move to New Window", systemImage: "macwindow.on.rectangle")
            }
        }
    }
}

/// New Tab / New Window (where there can be another window), then the
/// active tab's own menu. The iPad strip and the compact bar both open
/// this from their trailing ⋯.
///
/// New Tab is the same control the `+` is, so it opens as a submenu of
/// directories once there are any. On a phone with tabs open this is the
/// only new-tab control on screen — the bar shows the title capsule
/// instead — so the choice has to be reachable from here.
struct TabOverflowMenuContent: View {
    @ObservedObject var tabManager: TabManager
    let window: UIWindow?
    /// The New Tab rows this menu's host took (`NewTabSubmenu`).
    let newTabRows: NewTabMenuRows

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("TabOverflowMenuContent")
        #endif
        NewTabSubmenu(tabManager: tabManager, rows: newTabRows) {
            Label("New Tab", systemImage: "plus")
        }
        // A phone runs one scene; the request would do nothing there.
        if UIApplication.shared.supportsMultipleScenes {
            Button(action: { TerminalWindow.requestNewWindow() }) {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }
        }
        if let tab = tabManager.activeTab {
            Divider()
            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
        }
    }
}
