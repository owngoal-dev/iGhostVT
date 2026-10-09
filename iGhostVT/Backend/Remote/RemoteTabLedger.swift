import Foundation

/// The record of the app's remote tabs, so a cold launch reattaches them.
///
/// This device's own tabs need none of this: its daemon lists what is
/// left, and the launch window claims it (`DaemonSessionDirectory`). A paired device's
/// daemon has many clients and cannot say which of its terminals were
/// open here, and iOS kills a suspended app without telling it — so the
/// app writes down, whenever a window goes to the background, which
/// terminal on which device each tab was, and the first window of the next
/// launch opens them again. A session that ended in the meantime opens a
/// fresh shell on that device, the way a local tab whose session is gone
/// does.
@MainActor
enum RemoteTabLedger {
    struct Entry: Codable, Equatable {
        var hostID: String
        var sessionID: UInt64
    }

    private struct Record: Codable {
        var entries: [Entry]
        /// Which entry was the front tab, if it was one of them.
        var activeIndex: Int?
    }

    private static let key = "Remote.openTabs"
    /// One claim per process: the launch's first window takes every entry,
    /// and a window opened beside it starts on its own.
    private static var isClaimed = false

    /// Every window's remote tabs, in window order, written over the last
    /// record. A tab that has not reached its session yet has nothing to
    /// reattach to and is left out.
    static func save(_ managers: [TabManager]) {
        var entries: [Entry] = []
        var activeIndex: Int?
        for manager in managers {
            for tab in manager.tabs {
                guard let hostID = tab.remoteHostID, let sessionID = tab.remoteSessionID else { continue }
                if activeIndex == nil, tab.id == manager.activeTabID {
                    activeIndex = entries.count
                }
                entries.append(Entry(hostID: hostID, sessionID: sessionID))
            }
        }
        guard let data = try? JSONEncoder().encode(Record(entries: entries, activeIndex: activeIndex)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The last record, once per launch, minus devices no longer paired.
    static func claim() -> (entries: [Entry], activeIndex: Int?) {
        guard !isClaimed else { return ([], nil) }
        isClaimed = true
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return ([], nil) }
        let paired = Set(PairedRemoteHostStore.hosts.map(\.id))
        var entries: [Entry] = []
        var activeIndex: Int?
        for (index, entry) in record.entries.enumerated() where paired.contains(entry.hostID) {
            if index == record.activeIndex {
                activeIndex = entries.count
            }
            entries.append(entry)
        }
        return (entries, activeIndex)
    }
}

/// The device a new tab opens on in Ghost Remote when nothing else names
/// one: the one the last remote tab was opened on.
enum RemoteTabDefaults {
    private static let key = "Remote.lastHostID"

    static func noteOpened(onHostID hostID: String) {
        UserDefaults.standard.set(hostID, forKey: key)
    }

    /// The last device used while it is still paired, else one the browser
    /// can see right now, else any paired device; nil with none paired.
    @MainActor
    static var preferredHostID: String? {
        let paired = PairedRemoteHostStore.hosts
        if let last = UserDefaults.standard.string(forKey: key), paired.contains(where: { $0.id == last }) {
            return last
        }
        return RemoteHostDirectory.shared.reachablePaired.first?.id ?? paired.first?.id
    }
}
