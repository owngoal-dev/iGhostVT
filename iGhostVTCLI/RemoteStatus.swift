import Foundation
import XPC

/// What `remoteStatus` (and every other remote-access reply) says about
/// this device's helper.
struct RemoteStatus {
    struct Device {
        var id: String
        var name: String
        var pairedAt: Date?
        var lastSeen: Date?
    }

    var isEnabled: Bool
    var state: RemoteAccessState
    var failureMessage: String?
    var hostID: String?
    var hostName: String?
    var port: UInt64
    var appVersion: String?
    /// Present only while the helper runs; empty for no relay.
    var relayFingerprint: String?
    var relayState: RelayState
    var relayName: String?
    var relayMessage: String?
    var connectedCount: UInt64
    var devices: [Device]
    var pairingCode: String?
    var pairingExpiresAt: Date?
    var pairingFailureCount: Int

    init(_ reply: xpc_object_t) {
        isEnabled = xpc_dictionary_get_bool(reply, iGhostVTWireKey.enabled)
        state = DaemonClient.string(reply, iGhostVTWireKey.remoteState).flatMap(RemoteAccessState.init(rawValue:)) ?? .off
        failureMessage = DaemonClient.string(reply, iGhostVTWireKey.errorMessage)
        hostID = DaemonClient.string(reply, iGhostVTWireKey.hostID)
        hostName = DaemonClient.string(reply, iGhostVTWireKey.hostName)
        port = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.port)
        appVersion = DaemonClient.string(reply, iGhostVTWireKey.appVersion)
        relayFingerprint = DaemonClient.string(reply, iGhostVTWireKey.relayFingerprint)
        relayState = DaemonClient.string(reply, iGhostVTWireKey.relayState).flatMap(RelayState.init(rawValue:)) ?? .off
        relayName = DaemonClient.string(reply, iGhostVTWireKey.relayName)
        relayMessage = DaemonClient.string(reply, iGhostVTWireKey.relayMessage)
        connectedCount = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.connectedCount)
        devices = Self.entries(iGhostVTWireKey.devices, in: reply).compactMap { entry in
            guard let id = DaemonClient.string(entry, iGhostVTWireKey.deviceID) else { return nil }
            return Device(
                id: id,
                name: DaemonClient.string(entry, iGhostVTWireKey.deviceName) ?? id,
                pairedAt: Self.date(iGhostVTWireKey.time, in: entry),
                lastSeen: Self.date(iGhostVTWireKey.lastSeen, in: entry),
            )
        }
        pairingCode = DaemonClient.string(reply, iGhostVTWireKey.pairingCode)
        pairingExpiresAt = Self.date(iGhostVTWireKey.pairingExpiresAt, in: reply)
        pairingFailureCount = Self.entries(iGhostVTWireKey.pairingFailures, in: reply).count
    }

    private static func date(_ key: String, in dictionary: xpc_object_t) -> Date? {
        guard xpc_dictionary_get_value(dictionary, key) != nil else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(xpc_dictionary_get_int64(dictionary, key)))
    }

    private static func entries(_ key: String, in dictionary: xpc_object_t) -> [xpc_object_t] {
        guard let array = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return [] }
        return (0 ..< xpc_array_get_count(array)).map { xpc_array_get_value(array, $0) }
            .filter { xpc_get_type($0) == iGhostVTXPC.typeDictionary }
    }
}
