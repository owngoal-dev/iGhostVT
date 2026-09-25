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

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options: UIScene.ConnectionOptions,
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        tabManager.windowScene = windowScene
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
            rootView: RootView(tabManager: tabManager, interface: interface).interfaceTextSize(),
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        observeLaunchAgent()
        for context in options.urlContexts {
            ShortcutBridge.handle(context.url)
        }
    }

    /// An `ighostvt://` link while the app is running.
    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            ShortcutBridge.handle(context.url)
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

        @available(macCatalyst 16.0, *)
        func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry _: UIWindowScene.Geometry) {
            if !windowScene.effectiveGeometry.systemFrame.isEmpty {
                windowHasFrame = true
                liftWindowSizeCapIfReady(windowScene)
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
            }
    }

    func sceneDidDisconnect(_: UIScene) {
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
        #if targetEnvironment(macCatalyst)
            sceneIsActive = true
            if let windowScene = scene as? UIWindowScene {
                liftWindowSizeCapIfReady(windowScene)
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
        DaemonSessionDirectory.shared.refresh()
    }
}
