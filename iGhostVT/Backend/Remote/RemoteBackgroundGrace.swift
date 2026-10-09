import UIKit

/// The little while iOS lets an app keep running after it leaves the
/// screen, asked for whenever a remote tab is open.
///
/// A suspended app's links are down, and a remote tab pays for that on
/// return: a reconnect, a replay, and an upload or a ZMODEM transfer
/// given up halfway. Leaving for a moment — a glance at a message, a
/// copy from another app — should cost none of it, so going to the
/// background with a remote tab open begins a background task, and the
/// links stay up until it ends: on return, when iOS calls time, or when
/// the last remote tab goes. A local tab needs none of this: its shell is
/// the daemon's and outlives the app either way. The Mac never suspends
/// the app, so it asks for nothing.
@MainActor
enum RemoteBackgroundGrace {
    private static var task: UIBackgroundTaskIdentifier = .invalid
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        #if !targetEnvironment(macCatalyst)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { begin() }
                },
                center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { end(reason: "back in the foreground") }
                },
            ]
        #endif
    }

    /// A remote tab closed while the app was in the background: with none
    /// left there is nothing to keep running for.
    static func noteTabsChanged() {
        guard task != .invalid, !hasRemoteTab else { return }
        end(reason: "no remote tab left")
    }

    private static var hasRemoteTab: Bool {
        ShortcutBridge.tabManagers().contains { $0.tabs.contains(where: \.isRemote) }
    }

    private static func begin() {
        guard task == .invalid, hasRemoteTab else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Remote tabs") {
            MainActor.assumeIsolated { end(reason: "time is up") }
        }
        guard task != .invalid else { return }
        // Unbounded until the move to the background settles; never an Int
        // conversion, which traps on it.
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let budget = remaining < 3600 ? "up to \(Int(remaining)) s" : "as long as iOS allows"
        AppLog.info(.transport, "in the background with remote tabs open, keeping their links for \(budget)")
    }

    private static func end(reason: String) {
        guard task != .invalid else { return }
        AppLog.info(.transport, "background grace for remote tabs over: \(reason)")
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
