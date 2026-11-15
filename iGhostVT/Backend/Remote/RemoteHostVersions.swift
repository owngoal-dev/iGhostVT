import Combine
import Foundation
import XPC

/// What each paired device runs, for the Mac's Accessible Devices list:
/// the whole version and whether it updates itself.
///
/// A host from 1.6.30 says both in its answer to every hello
/// (`iGhostVTWireKey.installedVersion`, `selfUpdating`), and every link
/// says hello — a tab's, the session catalog's ask every half minute, an
/// update's — so the list fills in as the devices are asked anyway. A host
/// from before says neither; `probe` asks a Mac's updater for its version
/// instead. Kept in memory only: what a device ran last week is no answer.
@MainActor
final class RemoteHostVersions: ObservableObject {
    static let shared = RemoteHostVersions()

    struct Entry: Equatable {
        /// `CFBundleShortVersionString`, patch and all.
        var version: String
        /// Nil when the host did not say: one from before 1.6.30, or a
        /// helper that had not read its own signature yet.
        var updatesItself: Bool?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private var observer: NSObjectProtocol?
    private var probing: Set<String> = []

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: PairedRemoteHostStore.didChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let paired = Set(PairedRemoteHostStore.hosts.map(\.id))
                for hostID in self.entries.keys where !paired.contains(hostID) {
                    self.entries.removeValue(forKey: hostID)
                }
            }
        }
    }

    /// A hello's answer, from a link's queue. Only a success that names a
    /// version counts: a host from before 1.6.30 says none, and keeps what
    /// `probe` found.
    nonisolated static func note(_ reply: xpc_object_t, fromHostID hostID: String) {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_int64(reply, iGhostVTWireKey.code) == iGhostVTReplyCode.success.rawValue,
              let raw = xpc_dictionary_get_string(reply, iGhostVTWireKey.installedVersion)
        else { return }
        let version = String(cString: raw)
        guard !version.isEmpty, version != RemoteAccess.unknownVersion else { return }
        let updatesItself: Bool? = xpc_dictionary_get_value(reply, iGhostVTWireKey.selfUpdating) == nil
            ? nil
            : xpc_dictionary_get_bool(reply, iGhostVTWireKey.selfUpdating)
        let entry = Entry(version: version, updatesItself: updatesItself)
        Task { @MainActor in
            shared.set(entry, forHostID: hostID)
        }
    }

    /// What an update found the host running, as it said it.
    func note(_ status: HostUpdateStatus, fromHostID hostID: String) {
        let version = status.installedVersion
        guard !status.isOtherLine, !version.isEmpty, version != RemoteAccess.unknownVersion else { return }
        var entry = entries[hostID] ?? Entry(version: version)
        entry.version = version
        switch status.state {
        case .unsupported:
            entry.updatesItself = false
        case .upToDate, .available, .downloading, .verifying, .installing, .installed:
            // Only a Mac that updates itself gets this far.
            entry.updatesItself = true
        case .idle, .checking, .failed:
            break
        }
        set(entry, forHostID: hostID)
    }

    /// Asks each host not heard from in a hello for its version: a Mac's
    /// updater states what is installed whatever its release, without
    /// starting anything. A device's updater knows no version, and a host
    /// that does not answer stays unknown.
    func probe(_ hostIDs: [String]) {
        for hostID in hostIDs where entries[hostID] == nil && !probing.contains(hostID) {
            probing.insert(hostID)
            Task {
                let status = await HostUpdateClient.ask(at: .remote(hostID: hostID), timeout: 10)
                probing.remove(hostID)
                // A hello of 1.6.30 or later may have answered meanwhile,
                // and said more than the updater does.
                guard entries[hostID] == nil, let status else { return }
                note(status, fromHostID: hostID)
            }
        }
    }

    private func set(_ entry: Entry, forHostID hostID: String) {
        guard PairedRemoteHostStore.host(id: hostID) != nil, entries[hostID] != entry else { return }
        entries[hostID] = entry
    }
}
