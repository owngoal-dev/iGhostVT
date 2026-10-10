import Darwin
import Dispatch
import Foundation
import Network
import XPC

/// Everything the helper does, on one serial queue: the listener and its
/// Bonjour advertisement, the clients, the pairing window, the management
/// socket to the proxy, and the anchor connection that keeps the daemon
/// resident while this process runs.
final class RemoteService: RelayLinkHost {
    let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.remote",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let management: IOChannel
    private(set) var store = RemoteStore.load()
    private let deviceName = RemoteHostName.current()

    /// What this host is called: the name chosen in the app, or the one
    /// the owner gave the device.
    var hostName: String {
        store.hostName ?? deviceName
    }

    var relayHostID: String {
        store.hostID
    }

    private var listener: NWListener?
    private var listenerGeneration = 0
    /// The registration with a relay, when one is configured.
    private var relay: RelayLink?
    /// What relayed connections arrive on: a TLS listener of its own on
    /// the loopback address, with the same keys. Everything it accepts came
    /// through the relay — `RelayLink` splices each call back into it — so
    /// it is counted apart from the local network's listener: a stranger
    /// who knows the host id can fill the relay's slots, never the local
    /// ones, and pairing through it is refused unless the window allows it.
    private var relayListener: NWListener?
    private var relayListenerGeneration = 0
    private(set) var relayListenerPort: UInt16?
    /// Where each relayed connection came from, in the order the calls back
    /// were spliced; the relay listener takes them in the order it accepts.
    private var relayArrivals: [String] = []
    private var state: RemoteAccessState = .starting
    private var failureMessage: String?
    private var clients: [ObjectIdentifier: RemoteClient] = [:]
    /// Device connections that ended still holding terminals, kept for
    /// `RemoteAccess.reconnectGraceSeconds` (`RemoteClient.linger`).
    private var lingering: [ObjectIdentifier: RemoteClient] = [:]
    /// Accepted past the handshake limit, not started yet, oldest first.
    private var waiting: [(connection: NWConnection, address: String, viaRelay: Bool, since: Date)] = []
    private var anchor: xpc_connection_t?

    /// An open pairing window: one code, a few attempts, and the failed
    /// ones, each with where it came from.
    private struct PairingWindow {
        var code: String
        var expiresAt: Date
        var attemptsUsed = 0
        var failures: [(address: String, time: Date)] = []
        /// The client mid-exchange; one at a time.
        var activeClient: ObjectIdentifier?
        var activeClientViaRelay = false
        /// Whether a pairing may come in through the relay. Its attempts
        /// are counted apart: spending them shuts the relay out of this
        /// window and leaves the local network's attempts alone.
        var allowsRelay = false
        var relayAttemptsUsed = 0
    }

    private var pairing: PairingWindow?

    init(managementDescriptor: Int32) {
        management = IOChannel(descriptor: managementDescriptor, queue: queue)
    }

    func start() {
        queue.async { [self] in
            management.onFrame = { [weak self] header, payload in
                self?.handleManagement(header, payload: payload)
            }
            management.onClosed = {
                // The proxy is gone; it spawns a new helper when it comes
                // back, and the clients reconnect to that one.
                exit(EXIT_SUCCESS)
            }
            management.activate()
            RemoteLog.sink = { [weak self] line in
                self?.queue.async {
                    self?.forwardLog(line)
                }
            }
            RemoteLog.log("starting as uid \(getuid()), host \(store.hostID), \(store.devices.count) paired device(s)")
            connectAnchor()
            startListener()
            watchAddress()
            startRelay()
        }
    }

    /// The advertised address follows the network: a new one (another
    /// Wi-Fi, a renewed lease) is advertised again.
    private var advertisedAddress: String?
    private let pathMonitor = NWPathMonitor()

    private func watchAddress() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self, RemoteNetwork.localIPv4() != advertisedAddress, listener != nil else { return }
            RemoteLog.log("address changed, advertising again")
            restartListener()
        }
        pathMonitor.start(queue: queue)
    }

    // MARK: - The daemon

    /// One connection to the daemon held for as long as this process runs:
    /// with it the daemon never sees itself idle, which is what makes remote
    /// access keep it resident. A daemon restart drops it; it comes back.
    private func connectAnchor() {
        guard anchor == nil else { return }
        guard let connection = makeDaemonConnection() else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectAnchor() }
            return
        }
        anchor = connection
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard let self, xpc_get_type(event) == iGhostVTXPC.typeError else { return }
            anchor = nil
            xpc_connection_cancel(connection)
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectAnchor() }
        }
        xpc_connection_activate(connection)
        let hello = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
        xpc_connection_send_message_with_reply(connection, hello, queue) { _ in }
    }

    func makeDaemonConnection() -> xpc_connection_t? {
        iGhostVTProtocol.serviceName.withCString {
            ighostvtCreateMachServiceListener($0, queue, 0)
        }
    }

    // MARK: - Listener

    /// A new listener for a changed set of keys. The port is still the old
    /// one's until its cancel completes, so the new one is made then.
    private func restartListener() {
        if relay != nil {
            startRelayListener()
        }
        guard let old = listener else {
            startListener()
            return
        }
        listener = nil
        listenerGeneration += 1
        old.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.startListener()
            }
        }
        old.cancel()
    }

    private func startListener(bindAttempt: Int = 0) {
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        let generation = listenerGeneration
        let parameters = RemoteTLS.parameters(keys: listenerKeys())
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            guard let port = NWEndpoint.Port(rawValue: RemoteAccess.port) else { return }
            listener = try NWListener(using: parameters, on: port)
        } catch {
            fail("could not create the listener: \(error)", message: Self.describe(error))
            return
        }
        advertisedAddress = RemoteNetwork.localIPv4()
        listener.service = NWListener.Service(
            name: hostName,
            type: RemoteAccess.serviceType,
            domain: nil,
            txtRecord: Self.txtRecord([
                (RemoteAccess.TXTKey.hostID, store.hostID),
                (RemoteAccess.TXTKey.hostName, hostName),
                (RemoteAccess.TXTKey.version, RemoteAccess.protocolVersion),
                (RemoteAccess.TXTKey.address, advertisedAddress ?? ""),
                (RemoteAccess.TXTKey.appVersion, RemoteAccess.wireVersion),
            ]),
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, generation == listenerGeneration else { return }
            switch state {
            case .ready:
                self.state = .listening
                failureMessage = nil
                RemoteLog.log("listening on port \(RemoteAccess.port) as \(hostName)")
            case let .failed(error), let .waiting(error):
                // The port a moment after a restart, or after the helper
                // was replaced, can still be held by what released it:
                // asked again shortly, a few times, before it counts.
                if case let NWError.posix(code) = error, code == .EADDRINUSE, bindAttempt < 20 {
                    listener.cancel()
                    queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, generation == listenerGeneration else { return }
                        startListener(bindAttempt: bindAttempt + 1)
                    }
                    return
                }
                fail("listener: \(error)", message: Self.describe(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, viaRelay: false)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerKeys() -> [RemoteTLS.Key] {
        var keys = [RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey)]
        for device in store.devices {
            keys.append(RemoteTLS.Key(identity: Data(device.id.utf8), secret: device.key))
        }
        return keys
    }

    /// The relay listener, made again with the current keys. Its port is
    /// the system's choice and nobody but `RelayLink` dials it, so the new
    /// one need not wait for the old to let go.
    private func startRelayListener() {
        relayListener?.cancel()
        relayListener = nil
        relayListenerPort = nil
        relayListenerGeneration += 1
        let generation = relayListenerGeneration
        let parameters = RemoteTLS.parameters(keys: listenerKeys())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            RemoteLog.log("could not create the relay listener: \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, generation == relayListenerGeneration else { return }
            switch state {
            case .ready:
                relayListenerPort = listener.port?.rawValue
            case let .failed(error):
                RemoteLog.log("relay listener: \(error)")
                relayListenerPort = nil
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, generation == relayListenerGeneration else { return }
                    startRelayListener()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, viaRelay: true)
        }
        relayListener = listener
        listener.start(queue: queue)
    }

    // MARK: - Relay

    /// Registers with the configured relay, or stops: at start, and
    /// whenever the configuration changes.
    private func startRelay() {
        relay?.stop()
        relay = nil
        relayArrivals.removeAll()
        guard let data = store.relay else {
            relayListener?.cancel()
            relayListener = nil
            relayListenerPort = nil
            relayListenerGeneration += 1
            return
        }
        do {
            let configuration = try RelayConfiguration(data: data)
            let link = try RelayLink(service: self, configuration: configuration, hostKey: store.hostKey())
            relay = link
            startRelayListener()
            link.start()
        } catch {
            RemoteLog.log("the relay configuration is unusable: \(error)")
        }
    }

    /// A call back was spliced into the relay listener; its connection is
    /// next in line there.
    func noteRelayArrival(from address: String?) {
        relayArrivals.append(address ?? "")
        if relayArrivals.count > 16 {
            relayArrivals.removeFirst(relayArrivals.count - 16)
        }
    }

    /// The listener cannot run — the port is taken, most often. Reported
    /// through `remoteStatus`, and tried again every half minute in case
    /// whatever holds the port lets go.
    private func fail(_ logLine: String, message: String) {
        listener?.cancel()
        listener = nil
        state = .failed
        failureMessage = message
        RemoteLog.log(logLine)
        let generation = listenerGeneration
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, generation == listenerGeneration, state == .failed else { return }
            startListener()
        }
    }

    private static func describe(_ error: Error) -> String {
        if case let NWError.posix(code) = error, code == .EADDRINUSE {
            return "Port \(RemoteAccess.port) is in use by another program."
        }
        return "Remote access could not listen on port \(RemoteAccess.port) (\(error))."
    }

    private func accept(_ connection: NWConnection, viaRelay: Bool) {
        let address: String
        if viaRelay {
            let from = relayArrivals.isEmpty ? "" : relayArrivals.removeFirst()
            address = from.isEmpty ? "relay" : "\(from) via relay"
        } else {
            address = RemoteNetwork.addressDescription(connection.endpoint)
            guard RemoteNetwork.isLocal(connection.endpoint) else {
                RemoteLog.log("refused \(address): not a local network address")
                connection.cancel()
                return
            }
        }
        guard hasHandshakeSlot(viaRelay: viaRelay) else {
            guard waiting.filter({ $0.viaRelay == viaRelay }).count < RemoteAccess.maximumWaitingConnections else {
                RemoteLog.log("refused \(address): too many connections still handshaking")
                connection.cancel()
                return
            }
            waiting.append((connection, address, viaRelay, Date()))
            queue.asyncAfter(deadline: .now() + RemoteAccess.handshakeTimeoutSeconds) { [weak self] in
                guard let self, let index = waiting.firstIndex(where: { $0.connection === connection }) else { return }
                waiting.remove(at: index)
                RemoteLog.log("refused \(address): waited \(Int(RemoteAccess.handshakeTimeoutSeconds)) s for a handshake slot")
                connection.cancel()
            }
            return
        }
        start(connection, address: address, viaRelay: viaRelay)
    }

    private func hasHandshakeSlot(viaRelay: Bool) -> Bool {
        clients.values.filter { !$0.isAuthenticated && $0.viaRelay == viaRelay }.count
            < RemoteAccess.maximumUnauthenticatedConnections
    }

    private func start(_ connection: NWConnection, address: String, viaRelay: Bool) {
        let client = RemoteClient(connection: connection, address: address, viaRelay: viaRelay, service: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    /// A handshake slot came free: a client proved itself, or left.
    func handshakeEnded() {
        var index = 0
        while index < waiting.count {
            let next = waiting[index]
            guard hasHandshakeSlot(viaRelay: next.viaRelay) else {
                index += 1
                continue
            }
            waiting.remove(at: index)
            start(next.connection, address: next.address, viaRelay: next.viaRelay)
        }
    }

    /// The connection of `deviceID`, other than `client`, that holds
    /// `sessionID` — a live one, or one ended moments ago and lingering.
    func holder(of sessionID: UInt64, deviceID: String, other client: RemoteClient) -> RemoteClient? {
        (Array(clients.values) + Array(lingering.values)).first {
            $0 !== client && $0.deviceID == deviceID && $0.holds(sessionID)
        }
    }

    func clientLingering(_ client: RemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        lingering[ObjectIdentifier(client)] = client
    }

    func lingerEnded(_ client: RemoteClient) {
        lingering.removeValue(forKey: ObjectIdentifier(client))
    }

    func clientClosed(_ client: RemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        handshakeEnded()
        if pairing?.activeClient == ObjectIdentifier(client) {
            // Started and never finished: a guess was spent all the same.
            recordPairingFailure(address: client.address, reason: "abandoned")
        }
    }

    // MARK: - Devices

    func device(id: String) -> RemoteStore.Device? {
        store.device(id: id)
    }

    func noteSeen(deviceID: String, name: String?) {
        store.markSeen(deviceID: deviceID, name: name.map(RemoteAccess.sanitizedName))
    }

    // MARK: - Pairing

    /// `pairStart` from `client`: spends an attempt and answers with the
    /// host's share and confirmation, or with why not.
    func beginPairing(
        client: RemoteClient,
        deviceID: String,
        share: Data,
    ) -> Result<(exchange: PairingExchange, reply: xpc_object_t), PairingRefusal> {
        expirePairingIfNeeded()
        guard var window = pairing else {
            return .failure(.notOpen)
        }
        guard !client.viaRelay || window.allowsRelay else {
            return .failure(.notThroughRelay)
        }
        guard window.activeClient == nil else {
            return .failure(.busy)
        }
        guard store.devices.count < RemoteAccess.maximumDeviceCount || store.device(id: deviceID) != nil else {
            return .failure(.full)
        }
        if client.viaRelay {
            window.relayAttemptsUsed += 1
        } else {
            window.attemptsUsed += 1
        }
        window.activeClient = ObjectIdentifier(client)
        window.activeClientViaRelay = client.viaRelay
        pairing = window
        do {
            let exchange = try PairingExchange(role: .verifier, code: window.code)
            try exchange.receiveShare(share)
            let reply = xpc_dictionary_create(nil, nil, 0)
            try Self.setData(exchange.makeShare(), for: iGhostVTWireKey.share, in: reply)
            try Self.setData(exchange.makeConfirmation(), for: iGhostVTWireKey.confirmation, in: reply)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.hostID, store.hostID)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.hostName, hostName)
            RemoteLog.log("pairing attempt \(window.attemptsUsed) from \(client.address)")
            return .success((exchange, reply))
        } catch {
            recordPairingFailure(address: client.address, reason: "bad share")
            return .failure(.mismatch)
        }
    }

    /// `pairFinish` from `client`: the device is paired, or the attempt is
    /// recorded as failed.
    func finishPairing(
        client: RemoteClient,
        exchange: PairingExchange,
        deviceID: String,
        deviceName: String,
        confirmation: Data,
    ) -> Bool {
        guard pairing?.activeClient == ObjectIdentifier(client) else { return false }
        guard let sessionKey = try? exchange.verifyConfirmation(confirmation) else {
            recordPairingFailure(address: client.address, reason: "wrong code")
            return false
        }
        let key = PairingExchange.deviceKey(sessionKey: sessionKey, hostID: store.hostID, deviceID: deviceID)
        store.add(RemoteStore.Device(id: deviceID, name: deviceName, key: key, pairedAt: Date(), lastSeen: nil))
        pairing = nil
        RemoteLog.log("paired \(deviceName) (\(deviceID)) from \(client.address)")
        // The listener takes its keys when it is made; the new one has to be
        // among them before the device's first real connection.
        restartListener()
        return true
    }

    private func recordPairingFailure(address: String, reason: String) {
        guard var window = pairing else { return }
        let wasRelayed = window.activeClientViaRelay
        window.activeClient = nil
        window.activeClientViaRelay = false
        window.failures.append((address, Date()))
        RemoteLog.log("pairing attempt from \(address) failed: \(reason)")
        if wasRelayed {
            // The relay's attempts are its own: spent, they close the
            // window to the relay and nothing else.
            if window.relayAttemptsUsed >= RemoteAccess.pairingAttemptLimit, window.allowsRelay {
                RemoteLog.log("pairing through the relay closed after \(window.relayAttemptsUsed) attempts")
                window.allowsRelay = false
            }
            pairing = window
            return
        }
        if window.attemptsUsed >= RemoteAccess.pairingAttemptLimit {
            RemoteLog.log("pairing closed after \(window.attemptsUsed) attempts")
            pairing = nil
            for client in clients.values where client.isPairing {
                client.close(reason: "pairing closed")
            }
            return
        }
        pairing = window
    }

    private func expirePairingIfNeeded() {
        if let window = pairing, window.expiresAt <= Date() {
            pairing = nil
        }
    }

    // MARK: - Management

    private func handleManagement(_ header: IOWire.Header, payload: UnsafeRawBufferPointer) {
        guard header.kind == .request, let message = IOCodec.decode(payload) else { return }
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation))
        var code = iGhostVTReplyCode.success
        switch operation {
        case .remoteStatus:
            break
        case .beginPairing:
            pairing = PairingWindow(
                code: RemoteAccess.makePairingCode(),
                expiresAt: Date().addingTimeInterval(RemoteAccess.pairingWindowSeconds),
                allowsRelay: relay != nil && xpc_dictionary_get_bool(message, iGhostVTWireKey.relayPairing),
            )
            for client in clients.values where client.isPairing {
                client.close(reason: "a new pairing window opened")
            }
            RemoteLog.log("pairing window opened")
        case .endPairing:
            pairing = nil
            for client in clients.values where client.isPairing {
                client.close(reason: "pairing closed")
            }
        case .revokeRemoteDevice:
            let deviceID = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceID).map { String(cString: $0) }
            if let deviceID, store.remove(deviceID: deviceID) {
                RemoteLog.log("revoked device \(deviceID)")
                for client in clients.values where client.deviceID == deviceID {
                    client.close(reason: "device revoked")
                }
                for client in lingering.values where client.deviceID == deviceID {
                    client.endLinger()
                }
                restartListener()
            } else {
                code = .invalidRequest
            }
        case .setHostName:
            let requested = xpc_dictionary_get_string(message, iGhostVTWireKey.hostName)
                .map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            store.setHostName(requested.isEmpty ? nil : RemoteAccess.sanitizedName(requested))
            RemoteLog.log("host name is now \(hostName)")
            // The advertisement carries the name, and so does the relay's
            // list.
            restartListener()
            relay?.register()
        case .setRelayConfiguration:
            // Never logged: the payload holds the relay's private key.
            let data = Self.data(iGhostVTWireKey.relay, in: message) ?? Data()
            if data.isEmpty {
                store.setRelay(nil)
                RemoteLog.log("relay removed")
                startRelay()
            } else if let configuration = try? RelayConfiguration(data: data) {
                store.setRelay(configuration.encoded())
                RemoteLog.log("relay is now \(configuration.name) at \(configuration.endpointDescription)")
                startRelay()
            } else {
                code = .invalidRequest
            }
        default:
            code = .invalidRequest
        }
        guard header.tag != 0 else { return }
        let reply = statusReply()
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        _ = management.send(.reply, peer: header.peer, tag: header.tag, object: reply)
    }

    private func statusReply() -> xpc_object_t {
        expirePairingIfNeeded()
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_bool(reply, iGhostVTWireKey.enabled, true)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.remoteState, state.rawValue)
        if let failureMessage {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, failureMessage)
        }
        xpc_dictionary_set_string(reply, iGhostVTWireKey.hostID, store.hostID)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.hostName, hostName)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.appVersion, RemoteAccess.appVersion)
        let relayConfiguration = store.relay.flatMap { try? RelayConfiguration(data: $0) }
        xpc_dictionary_set_string(reply, iGhostVTWireKey.relayFingerprint, relayConfiguration?.fingerprint ?? "")
        if let relayConfiguration {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.relayName, relayConfiguration.name)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.relayState, (relay?.state ?? .failed).rawValue)
            if let message = relay?.message {
                xpc_dictionary_set_string(reply, iGhostVTWireKey.relayMessage, message)
            }
        } else {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.relayState, RelayState.off.rawValue)
        }
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.port, UInt64(RemoteAccess.port))
        xpc_dictionary_set_uint64(
            reply,
            iGhostVTWireKey.connectedCount,
            UInt64(clients.values.filter { $0.deviceID != nil }.count),
        )
        let devices = xpc_array_create(nil, 0)
        for device in store.devices {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.deviceID, device.id)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.deviceName, device.name)
            xpc_dictionary_set_int64(entry, iGhostVTWireKey.time, Int64(device.pairedAt.timeIntervalSince1970))
            if let lastSeen = device.lastSeen {
                xpc_dictionary_set_int64(entry, iGhostVTWireKey.lastSeen, Int64(lastSeen.timeIntervalSince1970))
            }
            xpc_array_append_value(devices, entry)
        }
        xpc_dictionary_set_value(reply, iGhostVTWireKey.devices, devices)
        if let pairing {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.pairingCode, pairing.code)
            xpc_dictionary_set_int64(
                reply,
                iGhostVTWireKey.pairingExpiresAt,
                Int64(pairing.expiresAt.timeIntervalSince1970),
            )
            let failures = xpc_array_create(nil, 0)
            for failure in pairing.failures {
                let entry = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(entry, iGhostVTWireKey.address, failure.address)
                xpc_dictionary_set_int64(entry, iGhostVTWireKey.time, Int64(failure.time.timeIntervalSince1970))
                xpc_array_append_value(failures, entry)
            }
            xpc_dictionary_set_value(reply, iGhostVTWireKey.pairingFailures, failures)
        }
        return reply
    }

    private func forwardLog(_ line: String) {
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(event, iGhostVTWireKey.errorMessage, line)
        _ = management.send(.event, peer: 0, tag: 0, object: event)
    }

    // MARK: - Helpers

    /// RFC 6763's TXT encoding — one length byte, then `key=value` — by
    /// hand, since `NWTXTRecord.data` is iOS 16.
    private static func txtRecord(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 {
                entry.removeLast(entry.count - 255)
            }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    static func setData(_ data: Data, for key: String, in dictionary: xpc_object_t) {
        data.withUnsafeBytes { buffer in
            xpc_dictionary_set_data(dictionary, key, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, buffer.count)
        }
    }

    static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

enum PairingRefusal: Error {
    case notOpen
    case notThroughRelay
    case busy
    case full
    case mismatch

    var message: String {
        switch self {
        case .notOpen: "Pairing is not open on this device. Choose Pair a Device on it first."
        case .notThroughRelay: "This device does not accept pairing through the relay. Pair on the same network, or allow pairing through the relay where the code is shown."
        case .busy: "Another device is pairing with this one. Try again in a moment."
        case .full: "This device has as many paired devices as it can hold. Remove one first."
        case .mismatch: "The code is incorrect."
        }
    }
}
