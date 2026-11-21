//
//  ShortcutBridge.swift
//  iGhostVT
//

import Foundation
import notify
import UIKit

/// Where a foreground intent (or an `ighostvt://` link) meets the windows.
/// The app has one `TabManager` per scene, so every request here starts by
/// picking a scene: the one showing the session if a tab already has it,
/// the frontmost one otherwise. Nothing here talks to the daemon except
/// through the tabs — a headless intent uses `ShortcutDaemonClient`.
@MainActor
enum ShortcutBridge {
    /// How long a request launched into a cold app waits for the first
    /// window to connect. `openAppWhenRun` brings the app up before the
    /// intent performs, but the scene can still be a beat behind.
    private static let sceneWait: UInt64 = 3_000_000_000

    /// Every connected window's tabs, frontmost first.
    static func tabManagers() -> [TabManager] {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { rank($0) < rank($1) }
        return scenes.compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
    }

    private static func rank(_ scene: UIWindowScene) -> Int {
        if isFrontmost(scene) {
            return 0
        }
        switch scene.activationState {
        case .foregroundActive: return 1
        case .foregroundInactive: return 2
        case .background: return 3
        case .unattached: return 4
        @unknown default: return 5
        }
    }

    /// Whether `scene` is the window in front. Every window on a Mac screen
    /// is `foregroundActive` at once; the one in front is the key window.
    private static func isFrontmost(_ scene: UIWindowScene) -> Bool {
        #if targetEnvironment(macCatalyst)
            scene.keyWindow?.isKeyWindow == true
        #else
            scene.activationState == .foregroundActive
        #endif
    }

    /// The frontmost window, waiting briefly for one to exist.
    private static func frontTabManager() async throws -> TabManager {
        let deadline = DispatchTime.now().uptimeNanoseconds + sceneWait
        while true {
            if let manager = tabManagers().first {
                return manager
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw ShortcutError.noWindow
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The tab attached to `sessionID`, in whichever window has it.
    private static func tab(for sessionID: UInt64) -> (TabManager, TerminalTab)? {
        for manager in tabManagers() {
            if let tab = manager.tabs.first(where: { $0.daemonSessionID == sessionID }) {
                return (manager, tab)
            }
        }
        return nil
    }

    /// Brings the session's tab to the front, attaching it to a new tab in
    /// the frontmost window when no tab has it. A session another window
    /// is showing brings that window forward.
    @discardableResult
    static func showSession(_ sessionID: UInt64, closesIfSessionIsGone: Bool = false) async throws -> TerminalTab {
        if let (manager, tab) = tab(for: sessionID) {
            manager.activate(tab)
            if let scene = manager.windowScene, !isFrontmost(scene) {
                UIApplication.shared.requestSceneSessionActivation(
                    scene.session,
                    userActivity: nil,
                    options: nil,
                    errorHandler: nil,
                )
            }
            return tab
        }
        let manager = try await frontTabManager()
        return manager.openTab(attachingTo: sessionID, closesIfSessionIsGone: closesIfSessionIsGone)
    }

    // MARK: - The command line

    private static var requestedSessionID: UInt64?
    private static var isHoldingShowRequests = false

    /// `ighostvt-cli app attach`: the id is the notification's state. Any
    /// process may post it, so the daemon is asked whether the session
    /// exists, at most four times a second, and a tab made for it never
    /// opens a shell of its own.
    static func observeShowRequests() {
        var token: Int32 = 0
        notify_register_dispatch(iGhostVTProtocol.showSessionNotification, &token, .main) { token in
            var sessionID: UInt64 = 0
            guard notify_get_state(token, &sessionID) == NOTIFY_STATUS_OK, sessionID > 0 else { return }
            MainActor.assumeIsolated {
                requestedSessionID = sessionID
                showRequestedSession()
            }
        }
    }

    private static func showRequestedSession() {
        guard !isHoldingShowRequests, let sessionID = requestedSessionID else { return }
        isHoldingShowRequests = true
        requestedSessionID = nil
        XPCDaemonTransport.listSessions { rows in
            guard rows?.contains(where: { $0.id == sessionID }) == true else { return }
            Task { @MainActor in
                _ = try? await showSession(sessionID, closesIfSessionIsGone: true)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isHoldingShowRequests = false
            showRequestedSession()
        }
    }

    /// The frontmost window's active tab's session — what a new tab opened
    /// from a Shortcut inherits its directory from, as ⌘T would.
    static func activeSessionID() -> UInt64? {
        tabManagers().first?.activeTab?.daemonSessionID
    }

    /// Opens a plain new tab in the frontmost window, the way ⌘T does.
    static func openNewTab() async throws -> TerminalTab {
        let manager = try await frontTabManager()
        // Only Ghost Remote with no device paired opens no tab.
        guard let tab = manager.newTab() else { throw ShortcutError.noWindow }
        return tab
    }

    /// Opens a tab on a paired device in the frontmost window (remote
    /// access): a fresh shell there, in its home or in `directory`.
    @discardableResult
    static func openRemoteTab(hostID: String, directory: TerminalDirectory? = nil) async throws -> TerminalTab {
        let manager = try await frontTabManager()
        guard let tab = manager.newTab(.remote(hostID: hostID, directory: directory)) else {
            throw ShortcutError.noWindow
        }
        return tab
    }

    /// The same, for a terminal the device already has open.
    @discardableResult
    static func openRemoteTab(hostID: String, attachingTo sessionID: UInt64) async throws -> TerminalTab {
        let manager = try await frontTabManager()
        return manager.openRemoteTab(attachingTo: sessionID, hostID: hostID)
    }

    // MARK: - URLs

    /// `ighostvt://session/<id>` shows a session; `ighostvt://new` opens a
    /// tab, optionally in a canonical directory. The scheme lets a Shortcut's
    /// Open URL, a widget, or another app reach a session, and nothing
    /// typed into a URL ever reaches a shell.
    static func handle(_ url: URL) {
        guard let link = TerminalLink(url) else { return }
        Task { @MainActor in
            switch link {
            case let .session(id):
                _ = try? await showSession(id)
            case let .new(directory):
                if let directory {
                    // A path from this device cannot name a directory on a
                    // paired host. Ghost Remote has no local shell.
                    guard !AppEdition.isRemoteOnly,
                          let manager = try? await frontTabManager() else { return }
                    _ = manager.newTab(.directory(TerminalDirectory(path: directory)))
                } else {
                    _ = try? await openNewTab()
                }
            }
        }
    }
}
