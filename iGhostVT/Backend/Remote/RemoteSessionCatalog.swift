import Combine
import UIKit

/// The terminals each paired device has open, for the new-tab menu: pick
/// one and it opens here (`TabManager.openRemoteTab`).
///
/// A SwiftUI menu is built from what is known when it opens, so the lists
/// are asked for ahead of time — as the app comes forward, and every half
/// minute while it stays there with a device to ask. Each ask is a fresh
/// connection to the device, so not more often than that. A device that does
/// not answer keeps its last list until it does, and a device that drops
/// out of sight for a moment — the relay's list failing once, Bonjour
/// losing it — keeps its list too; only unpairing takes it.
///
/// A menu needs to tell "no terminals" from "not heard from yet": just
/// after launch the relay and Bonjour have not answered, and an empty list
/// then read as a device with nothing open. `listing(of:)` says which.
@MainActor
final class RemoteSessionCatalog: ObservableObject {
    static let shared = RemoteSessionCatalog()

    @Published private(set) var sessions: [String: [XPCDaemonTransport.SessionSummary]] = [:]
    /// How each device's last ask went, and when.
    @Published private(set) var outcomes: [String: Outcome] = [:]
    /// True for a few seconds after the app comes forward: a paired device
    /// not found yet is still being looked for, not gone.
    @Published private(set) var isSettling = true

    struct Outcome: Equatable {
        var answered: Bool
        var at: Date
    }

    /// What a menu can say about one device's terminals.
    enum Listing: Equatable {
        /// It answered; empty when it holds none.
        case listed([XPCDaemonTransport.SessionSummary])
        /// Not heard from yet, and an ask is out or it is still being
        /// looked for.
        case loading
        /// Found, but its last ask got no answer.
        case notResponding
        /// Neither the browser, the relay nor a remembered address has it.
        case unreachable
    }

    func listing(of hostID: String) -> Listing {
        let directory = RemoteHostDirectory.shared
        let reachable = directory.paired.first { $0.id == hostID }.map(directory.isReachable) ?? false
        // A device that answered and is still there (or may be — looking
        // has only just begun) shows what it said, even while asked again.
        if outcomes[hostID]?.answered == true, reachable || isSettling {
            return .listed(sessions[hostID] ?? [])
        }
        if asking[hostID] != nil || isSettling {
            return .loading
        }
        guard reachable else { return .unreachable }
        return outcomes[hostID] == nil ? .loading : .notResponding
    }

    /// The greyed line a menu shows in place of a device's terminals, or
    /// nil for a list.
    static func statusText(_ listing: Listing) -> String? {
        switch listing {
        case .listed:
            nil
        case .loading:
            String(localized: "Connecting…")
        case .notResponding:
            String(localized: "Not Responding", comment: "Menu row: a paired device was found but did not answer with its terminals")
        case .unreachable:
            String(localized: "Not Reachable", comment: "Menu subtitle: a paired device neither the local network nor the relay can find")
        }
    }

    /// Whether the device has settled since `date`: answered, failed, or
    /// was found to be out of reach once looking was over.
    func hasSettled(_ hostID: String, since date: Date) -> Bool {
        // Dates are compared with `<` alone, everywhere: the 27.2 SDK makes
        // Foundation's `Date >=` and `<=` back-deployed, and a build with it
        // calls the OS's copy on 27.2, which some 27.2 betas do not have.
        if let outcome = outcomes[hostID], !(outcome.at < date), asking[hostID] == nil {
            return true
        }
        return listing(of: hostID) == .unreachable
    }

    private var settleTimer: Task<Void, Never>?
    private static let settleDelay: UInt64 = 8_000_000_000

    private var poll: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private static let interval: UInt64 = 30_000_000_000

    private init() {
        // A device the browser has just found is asked at once, rather
        // than at the next poll: the first one ran at launch, before
        // Bonjour had answered.
        RemoteHostDirectory.shared.$hosts
            .combineLatest(RemoteHostDirectory.shared.$paired, RemoteHostDirectory.shared.$relayHosts)
            .map { _, _, _ in RemoteHostDirectory.shared.reachablePaired.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                Task { @MainActor in await RemoteSessionCatalog.shared.refresh() }
            }
            .store(in: &subscriptions)
        // The Mac's menu bar keeps a deferred menu's first answer; a
        // rebuild is what makes it ask again (`AppMenus.remoteTabMenu`).
        $sessions
            .map { _ in () }
            .merge(with: RemoteHostDirectory.shared.$hosts.map { _ in () })
            .merge(with: RemoteHostDirectory.shared.$paired.map { _ in () })
            .merge(with: $outcomes.map { _ in () })
            .merge(with: $isSettling.map { _ in () })
            .merge(with: RecentDirectoryStore.shared.$remoteEntries.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { _ in
                UIMenuSystem.main.setNeedsRebuild()
            }
            .store(in: &subscriptions)
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { RemoteSessionCatalog.shared.resume() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { RemoteSessionCatalog.shared.pause() }
        })
        resume()
    }

    private func resume() {
        guard poll == nil else { return }
        isSettling = true
        settleTimer?.cancel()
        settleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.isSettling = false
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
    }

    private func pause() {
        poll?.cancel()
        poll = nil
    }

    /// Asks every paired device worth offering, all at once.
    func refresh() async {
        // The relay's list says which hosts are there to ask at all.
        await RemoteHostDirectory.shared.refreshRelay()
        let hosts = RemoteHostDirectory.shared.reachablePaired
            .filter { RemoteHostDirectory.shared.mismatchedVersion(of: $0.id) == nil }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { await self.refresh(hostID: host.id) }
            }
        }
        // An unpaired device takes its list with it; one merely out of
        // sight keeps it for when it is back.
        let paired = Set(RemoteHostDirectory.shared.paired.map(\.id))
        for hostID in sessions.keys where !paired.contains(hostID) {
            sessions.removeValue(forKey: hostID)
        }
        for hostID in outcomes.keys where !paired.contains(hostID) {
            outcomes.removeValue(forKey: hostID)
        }
    }

    /// The asks out now, by device: a second ask for the same device —
    /// the poll and an opening menu, say — waits for the first rather
    /// than opening a connection of its own.
    private var asking: [String: Task<Void, Never>] = [:]

    /// Asks one device for its terminals, unless it answered within
    /// `freshness` seconds.
    func refresh(hostID: String, freshness: TimeInterval = 0) async {
        if let ask = asking[hostID] {
            return await ask.value
        }
        if freshness > 0, let outcome = outcomes[hostID], outcome.answered,
           Date().timeIntervalSince(outcome.at) < freshness
        {
            return
        }
        let ask = Task { @MainActor in
            let rows = await Self.list(hostID: hostID)
            if let rows, sessions[hostID] != rows {
                sessions[hostID] = rows
            }
            // Done before the outcome is published, so whoever it wakes
            // reads this ask as over.
            asking[hostID] = nil
            outcomes[hostID] = Outcome(answered: rows != nil, at: Date())
        }
        asking[hostID] = ask
        await ask.value
    }

    private nonisolated static func list(hostID: String) async -> [XPCDaemonTransport.SessionSummary]? {
        await withCheckedContinuation { continuation in
            XPCDaemonTransport.listSessions(at: .remote(hostID: hostID)) { rows in
                continuation.resume(returning: rows)
            }
        }
    }
}

extension XPCDaemonTransport.SessionSummary: Identifiable {}
