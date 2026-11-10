import Foundation
import Network
import UIKit

/// This device as a remote-access client: one id for every host it pairs
/// with, made once, and the name it introduces itself by.
enum RemoteDeviceIdentity {
    private static let key = "Remote.deviceID"

    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    static let chosenNameKey = "Remote.deviceName"
    private static let systemNameKey = "Remote.systemDeviceName"

    /// Kept where a transport's queue can read it: UIDevice answers on the
    /// main thread only. Called as the app launches.
    @MainActor
    static func noteSystemName() {
        UserDefaults.standard.set(
            RemoteAccess.sanitizedName(DeviceNaming.meaningful(UIDevice.current.name)),
            forKey: systemNameKey,
        )
    }

    /// The name the owner gave the device in Settings.
    static var systemName: String {
        UserDefaults.standard.string(forKey: systemNameKey) ?? RemoteAccess.sanitizedName("")
    }

    /// The name chosen in Remote Access, nil for the device's own.
    static var chosenName: String? {
        get { UserDefaults.standard.string(forKey: chosenNameKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: chosenNameKey)
            } else {
                UserDefaults.standard.set(RemoteAccess.sanitizedName(trimmed), forKey: chosenNameKey)
            }
        }
    }

    /// What the other devices call this one: as a host it is advertised
    /// under it, as a client it pairs and connects under it.
    static var deviceName: String {
        chosenName ?? systemName
    }
}

/// The paired hosts (`PairedHostFile`), in the app's Application Support:
/// 0600, and on the device under data protection until the first unlock.
/// Read from the transport's queue as well as the main actor; `didChange`
/// tells the interface. `ighostvt-cli pair` writes the same file, and the
/// cache (`PairedHostCache`) brings that in as it happens — announced once,
/// and never for a write of this process's own.
enum PairedRemoteHostStore {
    static let didChange = Notification.Name("wiki.qaq.ighostvt.pairedRemoteHostsDidChange")

    private static let file = PairedHostCache(url: fileURL) {
        AppLog.info(.transport, "paired hosts changed on disk")
        notify()
    }

    static var hosts: [PairedRemoteHost] {
        file.hosts
    }

    static func host(id: String) -> PairedRemoteHost? {
        hosts.first { $0.id == id }
    }

    static func save(_ host: PairedRemoteHost) {
        modify { hosts in
            hosts.removeAll { $0.id == host.id }
            hosts.append(host)
            return true
        }
    }

    /// The user named the host; nil or blank goes back to its own name.
    static func setNickname(_ nickname: String?, forHostID id: String) {
        let trimmed = nickname.map { RemoteAccess.sanitizedName($0) }
        let value = (nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : trimmed
        update(id) { $0.nickname = value }
    }

    /// The host advertised itself under a new device name.
    static func syncName(_ name: String, forHostID id: String) {
        guard !name.isEmpty else { return }
        update(id) { $0.name = RemoteAccess.sanitizedName(name) }
    }

    private static func update(_ id: String, _ change: (inout PairedRemoteHost) -> Void) {
        modify { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
            var host = hosts[index]
            change(&host)
            guard host != hosts[index] else { return false }
            hosts[index] = host
            return true
        }
    }

    static func remove(id: String) {
        modify { hosts in
            let count = hosts.count
            hosts.removeAll { $0.id == id }
            return hosts.count != count
        }
    }

    /// The link reached the host: the address that answered, and when — kept up to date on every connection for a
    /// launch on which the browser has not found it. Through the relay
    /// only the time: the address that answered is the relay's, and kept
    /// as the host's it would send every later direct attempt there.
    static func noteReached(_ connection: NWConnection, forHostID id: String, viaRelay: Bool) {
        let address = viaRelay ? nil : rememberedAddress(of: connection, hostID: id)
        // Only the interface follows a host; a time is no change to tell.
        modify(announce: false) { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
            var host = hosts[index]
            host.lastAddress = address ?? host.lastAddress
            host.lastSeen = Date()
            guard host != hosts[index] else { return false }
            hosts[index] = host
            return true
        }
    }

    /// The IPv4 address to remember for a host a connection reached. Bonjour
    /// often resolves to IPv6, which is no address to show or to dial back:
    /// a link-local one routes nowhere without its interface, and a
    /// unique-local or temporary one changes under the host. The host's own
    /// advertised IPv4 stands in for it; with neither, nil keeps the last.
    static func rememberedAddress(of connection: NWConnection, hostID: String) -> String? {
        if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint,
           let address = RemoteNetwork.ipv4Description(host)
        {
            return address
        }
        return RemoteHostDirectory.advertisedAddress(forHostID: hostID)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
            // Unsandboxed on the Mac: Application Support is the user's own.
            return base.appendingPathComponent("iGhostVT/" + PairedHostFile.fileName)
        #else
            return base.appendingPathComponent(PairedHostFile.fileName)
        #endif
    }

    private static func modify(announce: Bool = true, _ change: (inout [PairedRemoteHost]) -> Bool) {
        let url = file.url
        let changed = file.modify(failed: {
            AppLog.error(.transport, "could not save paired hosts to \(url.path)")
        }, change)
        if changed, announce {
            notify()
        }
    }

    private static func notify() {
        Task { @MainActor in
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
