//
//  SceneDelegate.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

/// One window, one `TabManager`: every scene owns its tabs and their
/// connections, the way Safari windows own their tabs. When the system
/// discards the scene, the window's sessions are torn down with it.
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Read by `AppDelegate.applicationWillTerminate`, which walks every
    /// connected scene's tabs to decide what the quit closes.
    let tabManager = TabManager()
    private let interface = WindowInterfaceState()

    /// Watches the Mac's background helper. Nothing on iOS ever publishes.
    private var agentObserver: AnyCancellable?

    /// Whether a window has connected in this process yet. The first one is
    /// the launch's window, and it takes every session the last run left.
    private static var hasConnectedWindow = false
    #if targetEnvironment(macCatalyst)
        /// The scene sessions that existed as the first window connected:
        /// the windows the last run left, which macOS brings back one by
        /// one — not all before the first is active, so timing cannot tell
        /// them from a window opened since. A window opened in this run
        /// gets a session that is not in here.
        private static var restoredSessionIDs: Set<String> = []
    #endif
    /// A window restored at launch beside the first one, closed again
    /// before it built anything (`scene(_:willConnectTo:options:)`).
    private var isDiscarded = false

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions,
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let isFirstWindow = !Self.hasConnectedWindow
        Self.hasConnectedWindow = true
        #if targetEnvironment(macCatalyst)
            if isFirstWindow {
                Self.restoredSessionIDs = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
            }
            let isRestored = Self.restoredSessionIDs.remove(session.persistentIdentifier) != nil
            // After a crash (or a quit with windows open) macOS restores
            // every window the last run had. The daemon's sessions are the
            // only record of their tabs, and the first window claims them
            // all; each other window would come up holding one fresh shell
            // and nothing it used to show, so a tab looked lost in whichever
            // window was checked. One window comes back, holding every tab.
            if !isFirstWindow, isRestored {
                isDiscarded = true
                AppLog.info(.tabs, "closing a window restored beside the launch window")
                DispatchQueue.main.async {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                }
                return
            }
        #endif
        tabManager.windowScene = windowScene
        // A window opened for a tab moved out of another one: that window
        // lets go of the tab first, and this one attaches to its session.
        // The first window of a launch has no other window to take it from
        // — it is one restored with the request that once opened it — and
        // claims every leftover session, that one included.
        let movedSessionID = isFirstWindow ? nil : TabWindowMove.sessionID(in: options.userActivities)
        if let movedSessionID {
            TabWindowMove.releaseSource(of: movedSessionID, into: tabManager)
        }
        // Every other terminal window, background ones included: a window
        // opened beside one of them was asked for.
        let isOnlyWindow = ShortcutBridge.tabManagers().allSatisfy { $0 === tabManager }
        tabManager.populate(movingSession: movedSessionID, isOnlyWindow: isOnlyWindow)
        #if targetEnvironment(macCatalyst)
            // A tab pulled out of a strip opens its window where it was
            // dropped, once AppKit has a window to move
            // (`placeWindowIfPending`).
            if movedSessionID != nil {
                pendingWindowOrigin = TabWindowMove.origin(in: options.userActivities)
            }
        #endif
        #if targetEnvironment(macCatalyst)
            // No title bar: the app draws to the top edge and the traffic
            // lights float over its chrome (`CatalystWindowChrome`).
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
                titlebar.separatorStyle = .none
            }
            capInitialWindowSize(windowScene)
        #endif
        // The window answers the menu bar's commands for these tabs.
        let window = TerminalWindow(
            windowScene: windowScene,
            tabManager: tabManager,
            interface: interface,
        )
        let host = UIHostingController(
            rootView: RootView(tabManager: tabManager, interface: interface).interfaceTextSize().interfaceAccent().interfaceAppearance(),
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window

        observeLaunchAgent()
        for context in options.urlContexts {
            open(context.url)
        }
    }

    /// An `ighostvt://` link, or a relay configuration opened from Files or
    /// the Finder, while the app is running.
    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            open(context.url)
        }
    }

    private func open(_ url: URL) {
        if RelayImport.isConfiguration(url) {
            RelayImport.open(url, in: window)
        } else {
            ShortcutBridge.handle(url)
        }
    }

    #if targetEnvironment(macCatalyst)
        /// Catalyst opens a new window at most of the screen, which for a
        /// terminal is a wall of empty grid. Cap the window at a modest size
        /// — Terminal.app-sized plus the sidebar — while it is created, and
        /// lift the cap once it is up, so the system still places it and
        /// the person can still drag it as large as they like. A geometry
        /// request would need an origin, and the origin the scene reports
        /// while connecting is a placeholder that pins the window off the
        /// screen's bottom. Sizes are in the app's own points.
        private static let preferredWindowSize = CGSize(width: 1180, height: 780)
        private var windowSizeCap: CGSize?
        /// The cap comes off only when both are true: the scene is active
        /// *and* the window has a frame. Activation arrives first, while
        /// the reported frame is still empty; the window is sized between
        /// the two, and a cap lifted at activation never touches it.
        private var sceneIsActive = false
        private var windowHasFrame = false
        /// Where this window's top-left corner goes once it has a frame:
        /// under the pointer that pulled its tab out of another window.
        private var pendingWindowOrigin: CGPoint?

        private func capInitialWindowSize(_ windowScene: UIWindowScene) {
            guard let restrictions = windowScene.sizeRestrictions else { return }
            restrictions.minimumSize = CGSize(width: 620, height: 420)
            windowSizeCap = restrictions.maximumSize
            restrictions.maximumSize = Self.preferredWindowSize
        }

        private func liftWindowSizeCapIfReady(_ windowScene: UIWindowScene) {
            guard sceneIsActive, windowHasFrame,
                  let cap = windowSizeCap, let restrictions = windowScene.sizeRestrictions
            else { return }
            windowSizeCap = nil
            restrictions.maximumSize = cap
        }

        /// Moves a window opened for a dropped tab under the drop. Tried as
        /// the scene first reports a frame and again as it becomes active,
        /// whichever finds AppKit's window first — and once more a moment
        /// later, because AppKit cascades a new window after it is active
        /// and that undid a move made any sooner.
        private func placeWindowIfPending(_ windowScene: UIWindowScene) {
            guard let origin = pendingWindowOrigin, CatalystWindowChrome.frame(of: windowScene) != nil else { return }
            pendingWindowOrigin = nil
            CatalystWindowChrome.placeWindow(of: windowScene, topLeft: origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cascadeSettle) { [weak windowScene] in
                guard let windowScene else { return }
                CatalystWindowChrome.placeWindow(of: windowScene, topLeft: origin)
            }
        }

        /// Long enough for AppKit to have cascaded a new window.
        private static let cascadeSettle: TimeInterval = 0.25

        @available(macCatalyst 16.0, *)
        func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry _: UIWindowScene.Geometry) {
            if !windowScene.effectiveGeometry.systemFrame.isEmpty {
                windowHasFrame = true
                liftWindowSizeCapIfReady(windowScene)
                placeWindowIfPending(windowScene)
            }
        }
    #endif

    /// Approval happens in System Settings, outside the app, and there is no
    /// callback for it — the app finds out by looking. Two things look: the
    /// status re-read on every activation below, and this subscription, which
    /// turns "the helper is now running" into the connection attempt the tabs
    /// never got to make at launch.
    private func observeLaunchAgent() {
        agentObserver = MacLaunchAgent.shared.$status
            .removeDuplicates()
            // Only *transitions* to enabled. `@Published` replays its current
            // value on subscribe, and acting on that would start connecting
            // from `willConnectTo` — before the scene is active, which is the
            // one thing the auto-connect ordering exists to avoid.
            .dropFirst()
            .filter { $0 == .enabled }
            .sink { [weak self] _ in
                guard let self else { return }
                tabManager.noteSceneActive()
                tabManager.retryFailedTabs()
                tabManager.resumeLeftovers()
            }
    }

    func sceneDidDisconnect(_: UIScene) {
        // RootView's closure holds the view, which holds this state and the
        // tab manager: left set, the window's tabs would outlive it.
        interface.focusActiveTerminal = nil
        // A discarded window holds no tabs and never claimed the sessions;
        // detaching would hand the launch window's claim back.
        guard !isDiscarded else { return }
        tabManager.detachAllTabs()
    }

    /// Sessions auto-connect only from here on: the launch transition is
    /// over, layout has settled, and surfaces render unoccluded — the
    /// viewport a shell spawns with is the one the user actually sees.
    ///
    /// On the Mac there is one more precondition. The daemon is a bundled
    /// LaunchAgent a person has to allow once, and connecting before that is
    /// approved buys a guaranteed failure and a "Terminal Unavailable" card
    /// that names the wrong problem. So the first attempt waits for the
    /// helper, and `observeLaunchAgent()` makes it when the helper arrives.
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !isDiscarded else { return }
        #if targetEnvironment(macCatalyst)
            sceneIsActive = true
            if let windowScene = scene as? UIWindowScene {
                liftWindowSizeCapIfReady(windowScene)
                placeWindowIfPending(windowScene)
            }
        #endif
        MacLaunchAgent.shared.refresh()
        guard MacLaunchAgent.shared.isReady else { return }
        tabManager.noteSceneActive()
    }

    /// Nothing ends the Live Activity while the app isn't running, so a
    /// return to the foreground re-reads the daemon's registry — if the
    /// detached shells it was advertising died in the meantime, this is the
    /// moment the activity finds out and folds.
    func sceneWillEnterForeground(_: UIScene) {
        guard !isDiscarded else { return }
        if AppEdition.isRemoteOnly {
            // iOS dropped every link while the app was suspended: try them
            // now, not when each back-off timer gets round to it.
            tabManager.retryFailedTabs()
        } else {
            DaemonSessionDirectory.shared.refresh()
        }
    }

    /// Ghost Remote writes down its tabs here, the last moment it is sure
    /// to run before iOS may kill it (`RemoteTabLedger`).
    func sceneDidEnterBackground(_: UIScene) {
        guard AppEdition.isRemoteOnly, !isDiscarded else { return }
        RemoteTabLedger.save(ShortcutBridge.tabManagers())
    }
}
