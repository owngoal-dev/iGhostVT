import CryptoKit
import Foundation
import Network
@preconcurrency import XPC

/// Pairs this device with a host, given the code the host shows.
///
/// The link handshakes with the public pairing key (`RemoteAccess`) and
/// runs SPAKE2+ inside it as the prover: the host's confirmation is checked
/// before this side says anything that depends on the code, so a wrong code
/// — or a device pretending to be the host — fails here, and the host learns
/// only that one guess was wrong. On success both ends derive the same
/// device key, and the host is saved.
enum RemotePairingClient {
    enum Failure: LocalizedError {
        case unreachable
        case refused(String)
        case wrongCode
        case protocolError
        /// The host runs another iGhostVT; its version, or empty when it
        /// did not say.
        case versionMismatch(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                String(localized: "Unable to reach the other device. Check that remote access is on there, and that both devices are on the same network or use the same relay.")
            case let .versionMismatch(theirs):
                RemoteVersionText.mismatch(theirs: theirs, name: nil)
            case let .refused(message):
                message
            case .wrongCode:
                String(localized: "Incorrect code. Try again.")
            case .protocolError:
                String(localized: "Unable to pair. Try again.")
            }
        }
    }

    @MainActor
    static func pair(with host: DiscoveredRemoteHost, code: String) async throws -> PairedRemoteHost {
        let deviceID = RemoteDeviceIdentity.deviceID
        let deviceName = RemoteDeviceIdentity.deviceName
        // A host that advertises no version is older than the rule.
        if !RemoteAccess.isCompatible(host.appVersion ?? "") {
            throw Failure.versionMismatch(host.appVersion ?? "")
        }
        let session = PairingSession(endpoint: host.endpoint, hostID: host.id)
        defer { session.close() }
        let exchange = try PairingExchange(role: .prover, code: code)

        let start = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(start, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(start, iGhostVTWireKey.operation, iGhostVTOperation.pairStart.rawValue)
        xpc_dictionary_set_string(start, iGhostVTWireKey.deviceID, deviceID)
        xpc_dictionary_set_string(start, iGhostVTWireKey.deviceName, deviceName)
        xpc_dictionary_set_string(start, iGhostVTWireKey.appVersion, RemoteAccess.wireVersion)
        try set(exchange.makeShare(), iGhostVTWireKey.share, in: start)
        let answer = try await session.request(start)
        try check(answer)
        guard let hostShare = data(iGhostVTWireKey.share, in: answer),
              let hostConfirmation = data(iGhostVTWireKey.confirmation, in: answer),
              let hostID = xpc_dictionary_get_string(answer, iGhostVTWireKey.hostID).map({ String(cString: $0) }),
              let hostName = xpc_dictionary_get_string(answer, iGhostVTWireKey.hostName).map({ String(cString: $0) })
        else { throw Failure.protocolError }
        // Pairing starts only from a host Bonjour or the relay listed, and
        // the one that answers has to be the one the list named.
        guard hostID == host.id, hostID != RemoteHostDirectory.storedOwnHostID else { throw Failure.protocolError }

        try exchange.receiveShare(hostShare)
        let sessionKey: SymmetricKeyBox
        do {
            sessionKey = try SymmetricKeyBox(exchange.verifyConfirmation(hostConfirmation))
        } catch {
            throw Failure.wrongCode
        }
        let finish = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(finish, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(finish, iGhostVTWireKey.operation, iGhostVTOperation.pairFinish.rawValue)
        try set(exchange.makeConfirmation(), iGhostVTWireKey.confirmation, in: finish)
        try await check(session.request(finish))

        let paired = PairedRemoteHost(
            id: hostID,
            name: RemoteAccess.sanitizedName(hostName),
            // Pairing again keeps the name the user gave it.
            nickname: PairedRemoteHostStore.host(id: hostID)?.nickname,
            deviceID: deviceID,
            deviceKey: PairingExchange.deviceKey(sessionKey: sessionKey.key, hostID: hostID, deviceID: deviceID),
            pairedAt: Date(),
            // Through the relay the address that answered is the relay's.
            lastAddress: host.viaRelay ? nil : PairedRemoteHostStore.rememberedAddress(of: session.connection, hostID: hostID),
            lastSeen: Date(),
        )
        PairedRemoteHostStore.save(paired)
        AppLog.info(.transport, "paired with \(paired.name) (\(hostID))")
        return paired
    }

    private static func check(_ reply: xpc_object_t) throws {
        let code = iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code))
        if code == .unsupportedVersion {
            throw Failure.versionMismatch(xpc_dictionary_get_string(reply, iGhostVTWireKey.appVersion).map { String(cString: $0) } ?? "")
        }
        guard code == .success else {
            if let message = xpc_dictionary_get_string(reply, iGhostVTWireKey.errorMessage) {
                throw Failure.refused(String(cString: message))
            }
            throw Failure.protocolError
        }
    }

    private static func set(_ value: Data, _ key: String, in dictionary: xpc_object_t) {
        value.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(dictionary, key, base, buffer.count)
            }
        }
    }

    private static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

/// A session key carried across an `await`.
private struct SymmetricKeyBox: @unchecked Sendable {
    let key: SymmetricKey
    init(_ key: SymmetricKey) {
        self.key = key
    }
}

/// One pairing connection: requests in, replies out, in order.
private final class PairingSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.pairing")
    private let frames: RemoteFrameConnection
    private var waiting: [UInt64: CheckedContinuation<xpc_object_t, Error>] = [:]
    private var nextTag: UInt64 = 1
    private var closedReason: String?

    init(endpoint: NWEndpoint, hostID: String) {
        let parameters = RemoteTLS.parameters(
            keys: [RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey)],
            serverName: hostID,
        )
        RemoteNetwork.keepOnLocalNetwork(parameters, to: endpoint)
        frames = RemoteFrameConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
        frames.onFrame = { [weak self] header, object in
            guard let self, header.kind == .reply else { return }
            waiting.removeValue(forKey: header.tag)?.resume(returning: object)
        }
        frames.onClosed = { [weak self] reason in
            guard let self else { return }
            closedReason = reason
            let pending = waiting
            waiting.removeAll()
            for continuation in pending.values {
                continuation.resume(throwing: RemotePairingClient.Failure.unreachable)
            }
        }
        queue.async { [frames] in
            frames.start()
        }
    }

    func request(_ message: xpc_object_t) async throws -> xpc_object_t {
        let box = MessageBox(message)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard closedReason == nil else {
                    continuation.resume(throwing: RemotePairingClient.Failure.unreachable)
                    return
                }
                let tag = nextTag
                nextTag &+= 1
                waiting[tag] = continuation
                frames.send(.request, tag: tag, object: box.message)
                // A host that never answers is as good as unreachable.
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.waiting.removeValue(forKey: tag)?.resume(throwing: RemotePairingClient.Failure.unreachable)
                }
            }
        }
    }

    func close() {
        queue.async { [frames] in
            frames.close(reason: "pairing over")
        }
    }

    var connection: NWConnection {
        frames.connection
    }
}

private struct MessageBox: @unchecked Sendable {
    let message: xpc_object_t
    init(_ message: xpc_object_t) {
        self.message = message
    }
}
