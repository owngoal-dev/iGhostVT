//
//  NetworkPathWatcher.swift
//  iGhostVT
//

import Foundation
import Network

/// The device's network, as far as remote links care: whether there is one,
/// and when it changes to another.
///
/// A link to another device dies with the network it ran on, and TCP takes
/// half a minute or more to say so — keepalive for an idle link, the drop
/// time for a busy one — while the tab's back-off goes on spending its
/// minute against no network at all. Wi-Fi coming back found the next try
/// up to fifteen seconds away, or the tab already failed. So the links ask
/// the host whether it is still there the moment the path changes, and the
/// tabs try again the moment there is a path again.
final class NetworkPathWatcher: @unchecked Sendable {
    static let shared = NetworkPathWatcher()

    /// Posted on the main queue, after the path settled for a moment, when
    /// the network came back or moved to other interfaces. `isSatisfied`
    /// in `userInfo` says which: false is the network going away.
    static let pathDidChange = Notification.Name("wiki.qaq.ighostvt.network-path-changed")
    static let isSatisfiedKey = "isSatisfied"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.network-path")
    private let lock = NSLock()
    /// True until the monitor says otherwise: a watcher that has not heard
    /// yet must never hold a tab back.
    private var satisfied = true
    private var signature: String?
    private var settleGeneration = 0

    /// A handover (Wi-Fi to cellular, a hotspot rejoining) reports two or
    /// three paths in quick succession; only the one it settles on counts.
    private static let settleDelay: TimeInterval = 0.4

    var isSatisfied: Bool {
        lock.withLock { satisfied }
    }

    private init() {}

    /// Starts watching; idempotent, and cheap enough to call at launch.
    func start() {
        lock.withLock {
            guard monitor.pathUpdateHandler == nil else { return }
            monitor.pathUpdateHandler = { [weak self] path in
                self?.pathChanged(path)
            }
            monitor.start(queue: queue)
        }
    }

    private func pathChanged(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        let signature = isSatisfied
            ? path.availableInterfaces.map(\.name).joined(separator: ",")
            : "unsatisfied"
        let previous = lock.withLock {
            defer {
                self.signature = signature
                satisfied = isSatisfied
            }
            return self.signature
        }
        // The first report is where the device already was, not a change.
        guard let previous, previous != signature else { return }
        AppLog.info(.transport, "network path: \(signature)")
        settleGeneration += 1
        let generation = settleGeneration
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, settleGeneration == generation else { return }
            let settled = self.isSatisfied
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.pathDidChange,
                    object: nil,
                    userInfo: [Self.isSatisfiedKey: settled],
                )
            }
        }
    }
}
