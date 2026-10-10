import Darwin
import Dispatch
import Foundation
import Network
import XPC

/// One network connection. Its first frame decides what it is (see
/// `RemoteAccess`): a paired device proving which one it is, or a pairing.
/// A device then gets a daemon connection of its own, so the daemon sees
/// each device as a separate peer — an attach is exclusive per peer, and a
/// device's tabs must not share one with another device's.
///
/// Only the session operations reach the daemon. Shutdown and remote-access
/// management are refused here, and the proxy refuses them from this
/// process as well.
final class RemoteClient {
    let address: String
    /// Came in through the relay (`RelayLink`), not from the local network.
    let viaRelay: Bool
    private unowned let service: RemoteService
    private let frames: RemoteFrameConnection

    private enum Mode {
        case handshaking
        case pairing(deviceID: String, deviceName: String, exchange: PairingExchange)
        case session(deviceID: String)
    }

    private var mode = Mode.handshaking {
        didSet {
            if case .handshaking = oldValue, isAuthenticated {
                service.handshakeEnded()
            }
        }
    }
    private var daemon: xpc_connection_t?
    private var isDaemonSuspended = false
    private var isClosed = false
    /// The sessions this connection's daemon peer holds, as far as the
    /// replies and events said: what a reconnect of the same device picks
    /// up, and whether an ended connection has anything to linger for.
    private var heldSessions: Set<UInt64> = []
    /// Ended without letting go of `heldSessions`; the daemon peer is kept
    /// for `RemoteAccess.reconnectGraceSeconds` (`linger`).
    private var isLingering = false
    /// When the device last sent anything; a relayed one that goes quiet
    /// past `RemoteAccess.deviceSilenceLimit` is dropped.
    private var lastHeard = Date()

    /// The device output toward which may be held in the daemon instead of
    /// here: past this much not yet taken by the network, the daemon
    /// connection is suspended, which the proxy feels as a slow peer.
    /// The band is narrow on purpose: the proxy cuts a peer that takes
    /// nothing for `IOSupervisor.peerCongestionGrace`, and while suspended
    /// this connection takes nothing — draining 768 KiB before resuming
    /// was more than ten seconds over a slow relay, and an `sz` died there.
    private static let pauseAboveByteCount = 512 * 1024
    private static let resumeBelowByteCount = 384 * 1024
    /// While paused, the connection is let go for one message this often,
    /// so a link that is slow but draining — a relay at a few dozen KiB/s,
    /// a stall of ten seconds or twenty — never reads to the proxy as a
    /// peer that took nothing for its grace: it cut such a device with a
    /// megabyte in flight, and an `sz` or a flood's tail went with it. The
    /// buffer can only grow by a message per interval, and not past
    /// `trickleCeilingByteCount`; a device that drains nothing at all is
    /// still cut.
    private static let trickleInterval: DispatchTimeInterval = .seconds(3)
    private static let trickleCeilingByteCount = 8 << 20
    private var trickleGeneration = 0
    /// What the device last said it received (`iGhostVTWireKey.received`);
    /// `nil` until it says, as an app before the link window never does,
    /// and then only `pending` paces it.
    private var deviceReceivedByteCount: UInt64?

    /// The operations a paired device may send, all of them the app's own.
    private static let sessionOperations: Set<iGhostVTOperation> = [
        .hello, .listSessions, .openSession, .attachSession, .detachSession, .write, .resize,
        .closeSession, .goodbye, .snapshotSession, .injectInput, .listShells, .setSessionAttributes,
        .uploadFile,
    ]

    var isAuthenticated: Bool {
        if case .handshaking = mode {
            return false
        }
        return true
    }

    var isPairing: Bool {
        if case .pairing = mode {
            return true
        }
        return false
    }

    var deviceID: String? {
        if case let .session(deviceID) = mode {
            return deviceID
        }
        return nil
    }

    init(connection: NWConnection, address: String, viaRelay: Bool, service: RemoteService) {
        self.address = address
        self.viaRelay = viaRelay
        self.service = service
        frames = RemoteFrameConnection(connection: connection, queue: service.queue)
    }

    func start() {
        frames.maximumPayloadByteCount = RemoteAccess.maximumUnauthenticatedPayloadByteCount
        frames.onFrame = { [weak self] header, object in
            self?.handle(header, object)
        }
        frames.onClosed = { [weak self] reason in
            self?.closed(reason: reason)
        }
        frames.onPendingChange = { [weak self] pending in
            self?.updateDaemonPause(pending: pending)
        }
        frames.start()
        service.queue.asyncAfter(deadline: .now() + RemoteAccess.handshakeTimeoutSeconds) { [weak self] in
            guard let self, !isClosed else { return }
            if case .handshaking = mode {
                close(reason: "no first frame in \(Int(RemoteAccess.handshakeTimeoutSeconds)) s")
            }
        }
    }

    /// Ends the connection once what was already sent has left — a reply
    /// written just before (a pairing's outcome, a refusal) would otherwise
    /// be dropped with it.
    func close(reason: String) {
        RemoteLog.log("closing \(address): \(reason)")
        frames.closeWhenFlushed()
    }

    private func closed(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        if case let .session(deviceID) = mode {
            RemoteLog.log("device \(deviceID) at \(address) disconnected: \(reason)")
        }
        if let daemon, isDaemonSuspended {
            isDaemonSuspended = false
            xpc_connection_resume(daemon)
        }
        // A device that let go of everything (a tab closed or detached
        // sends that first) is simply gone. One that did not — Wi-Fi
        // dropped, the phone locked — may be back in a moment.
        if daemon != nil, !heldSessions.isEmpty {
            linger()
            return
        }
        cancelDaemon()
        service.clientClosed(self)
    }

    /// Keeps the daemon peer, and with it every terminal this connection
    /// held, for a grace period: a reconnect of the same device attaches
    /// them again (`stamped` takes them from this connection) and the host
    /// never notices. Output meanwhile is dropped — the reattach replays
    /// the screen — so the proxy sees a peer that keeps up. When the grace
    /// ends the peer goes, and the host takes back what is left.
    private func linger() {
        isLingering = true
        RemoteLog.log("keeping \(heldSessions.count) terminal(s) of \(address) for \(Int(RemoteAccess.reconnectGraceSeconds)) s")
        service.clientLingering(self)
        service.queue.asyncAfter(deadline: .now() + RemoteAccess.reconnectGraceSeconds) { [weak self] in
            self?.endLinger()
        }
    }

    func endLinger() {
        guard isLingering else { return }
        isLingering = false
        cancelDaemon()
        service.lingerEnded(self)
    }

    private func cancelDaemon() {
        guard let daemon else { return }
        xpc_connection_cancel(daemon)
        self.daemon = nil
    }

    /// A link can look alive at every TCP hop and be dead end to end — a
    /// relay leg, a NAT, a phone gone to sleep; the device pings a quiet
    /// link, so silence means it is gone.
    private func watchSilence() {
        let interval = RemoteAccess.deviceSilenceLimit / 3
        service.queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, !isClosed else { return }
            if Date().timeIntervalSince(lastHeard) > RemoteAccess.deviceSilenceLimit {
                close(reason: "nothing from the device in \(Int(RemoteAccess.deviceSilenceLimit)) s")
            } else {
                watchSilence()
            }
        }
    }

    func holds(_ sessionID: UInt64) -> Bool {
        heldSessions.contains(sessionID)
    }

    /// A reconnect of the same device took `sessionID` from this
    /// connection. A lingering one with nothing left goes now.
    func yield(_ sessionID: UInt64) {
        heldSessions.remove(sessionID)
        if isLingering, heldSessions.isEmpty {
            endLinger()
        }
    }

    // MARK: - Frames

    private func handle(_ header: IOWire.Header, _ object: xpc_object_t) {
        lastHeard = Date()
        guard header.kind == .request, xpc_get_type(object) == iGhostVTXPC.typeDictionary else {
            return close(reason: "a frame that is not a request")
        }
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(object, iGhostVTWireKey.operation))
        switch mode {
        case .handshaking:
            if operation == .hello || operation == .pairStart, !isSameVersion(object, tag: header.tag) {
                return
            }
            switch operation {
            case .hello: authenticate(object, tag: header.tag)
            case .pairStart: startPairing(object, tag: header.tag)
            default: close(reason: "first frame was neither hello nor pairStart")
            }
        case let .pairing(deviceID, deviceName, exchange):
            guard operation == .pairFinish,
                  let confirmation = RemoteService.data(iGhostVTWireKey.confirmation, in: object)
            else { return close(reason: "unexpected frame while pairing") }
            let paired = service.finishPairing(
                client: self,
                exchange: exchange,
                deviceID: deviceID,
                deviceName: deviceName,
                confirmation: confirmation,
            )
            mode = .handshaking
            if paired {
                reply(.success, tag: header.tag)
            } else {
                reply(.invalidRequest, tag: header.tag, message: PairingRefusal.mismatch.message)
            }
            close(reason: paired ? "paired" : "pairing failed")
        case .session:
            if operation == .ping {
                if xpc_dictionary_get_value(object, iGhostVTWireKey.received) != nil {
                    deviceReceivedByteCount = xpc_dictionary_get_uint64(object, iGhostVTWireKey.received)
                    updateDaemonPause(pending: frames.pendingByteCount)
                }
                reply(.success, tag: header.tag)
                return
            }
            guard let operation, Self.sessionOperations.contains(operation) else {
                reply(.invalidRequest, tag: header.tag)
                return
            }
            forward(stamped(object, operation: operation), tag: header.tag, operation: operation)
        }
    }

    /// Two devices talk only on the same release line (`isCompatible`):
    /// the other side is told which version this one runs, so it can say
    /// which of the two needs updating. A device that sends no version is
    /// older than the rule, and different by definition.
    private func isSameVersion(_ message: xpc_object_t, tag: UInt64) -> Bool {
        let theirs = xpc_dictionary_get_string(message, iGhostVTWireKey.appVersion).map { String(cString: $0) }
        guard !RemoteAccess.isCompatible(theirs) else { return true }
        RemoteLog.log("refused \(address): it runs iGhostVT \(theirs ?? "older than 1.4"), this host \(RemoteAccess.appVersion)")
        if tag != 0 {
            let reply = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, iGhostVTReplyCode.unsupportedVersion.rawValue)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.appVersion, RemoteAccess.wireVersion)
            xpc_dictionary_set_string(
                reply,
                iGhostVTWireKey.errorMessage,
                "The other device runs iGhostVT \(RemoteAccess.lineDescription(RemoteAccess.appVersion)). Update both devices to the same version to connect.",
            )
            frames.send(.reply, tag: tag, object: reply)
        }
        close(reason: "different iGhostVT version")
        return false
    }

    // MARK: - A paired device

    /// `hello` with `deviceID` and its proof. The proof is checked against
    /// this TLS session's exporter secret, so it names the device whose key
    /// the handshake used and cannot have been lifted from another session.
    private func authenticate(_ hello: xpc_object_t, tag: UInt64) {
        guard let deviceID = xpc_dictionary_get_string(hello, iGhostVTWireKey.deviceID).map({ String(cString: $0) }),
              let proof = RemoteService.data(iGhostVTWireKey.confirmation, in: hello),
              let device = service.device(id: deviceID),
              let exporter = RemoteTLS.exporterSecret(of: frames.connection),
              RemoteDeviceProof.verify(proof, key: device.key, exporterSecret: exporter, deviceID: deviceID)
        else {
            RemoteLog.log("refused \(address): no valid device proof")
            reply(.invalidRequest, tag: tag, message: "This device is not paired with the host. Pair it again.")
            close(reason: "authentication failed")
            return
        }
        guard let daemon = service.makeDaemonConnection() else {
            reply(.operationFailed, tag: tag, message: "The terminal helper on the host is not running.")
            close(reason: "no daemon")
            return
        }
        mode = .session(deviceID: deviceID)
        // A device that will report what it receives says so in its hello,
        // so the window holds from the first byte: waiting for its first
        // receipt let the network stack take 9 MB before the window began.
        if xpc_dictionary_get_value(hello, iGhostVTWireKey.received) != nil {
            deviceReceivedByteCount = 0
        }
        frames.maximumPayloadByteCount = IOWire.maximumPayloadByteCount
        self.daemon = daemon
        service.noteSeen(
            deviceID: deviceID,
            name: xpc_dictionary_get_string(hello, iGhostVTWireKey.deviceName).map { String(cString: $0) },
        )
        RemoteLog.log("device \(device.name) (\(deviceID)) connected from \(address)")
        // Relayed only: an app before 1.4.19 pings no direct link, and every
        // patch of a line talks to every other.
        if viaRelay {
            watchSilence()
        }
        xpc_connection_set_event_handler(daemon) { [weak self] event in
            self?.daemonEvent(event)
        }
        xpc_connection_activate(daemon)
        // The daemon's own hello, without the device's keys in it.
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, xpc_dictionary_get_uint64(hello, iGhostVTWireKey.version))
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
        forward(message, tag: tag)
    }

    /// What the daemon is told about the device on its behalf, never taken
    /// from the device: the name a session is opened or held for — the tab
    /// the host shows for it says where it is. `takeover` stays the
    /// device's to ask (the user picked the terminal, or chose Use Here);
    /// a reconnect does not, so a device coming back cannot take a
    /// terminal the host picked up meanwhile. The session events are the
    /// host app's, not a device's to ask for.
    private func stamped(_ message: xpc_object_t, operation: iGhostVTOperation) -> xpc_object_t {
        let copy = xpc_copy(message) ?? message
        xpc_dictionary_set_value(copy, iGhostVTWireKey.holder, nil)
        xpc_dictionary_set_value(copy, iGhostVTWireKey.watchSessions, nil)
        if operation == .openSession || operation == .attachSession,
           let deviceID, let device = service.device(id: deviceID)
        {
            xpc_dictionary_set_string(copy, iGhostVTWireKey.holder, device.name)
        }
        // This device's own earlier connection still has it — the link
        // dropped and the tab reconnected: it is the same holder, so it is
        // taken over quietly; nobody else was using it.
        if operation == .attachSession, let deviceID,
           service.holder(of: xpc_dictionary_get_uint64(copy, iGhostVTWireKey.sessionID), deviceID: deviceID, other: self) != nil
        {
            xpc_dictionary_set_bool(copy, iGhostVTWireKey.takeover, true)
        }
        return copy
    }

    /// Keeps `heldSessions` in step with what this peer asked for and was
    /// granted.
    private func noteGranted(_ operation: iGhostVTOperation, request: xpc_object_t, reply: xpc_object_t) {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_int64(reply, iGhostVTWireKey.code) == iGhostVTReplyCode.success.rawValue
        else { return }
        switch operation {
        case .openSession:
            heldSessions.insert(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID))
        case .attachSession:
            let sessionID = xpc_dictionary_get_uint64(request, iGhostVTWireKey.sessionID)
            heldSessions.insert(sessionID)
            if let deviceID, let previous = service.holder(of: sessionID, deviceID: deviceID, other: self) {
                previous.yield(sessionID)
            }
        default:
            break
        }
    }

    private func forward(_ message: xpc_object_t, tag: UInt64, operation: iGhostVTOperation? = nil) {
        guard let daemon else { return }
        // Letting go is known the moment it is sent.
        if operation == .detachSession || operation == .closeSession {
            heldSessions.remove(xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID))
        }
        guard tag != 0 else {
            xpc_connection_send_message(daemon, message)
            return
        }
        xpc_connection_send_message_with_reply(daemon, message, service.queue) { [weak self] reply in
            guard let self else { return }
            if let operation {
                noteGranted(operation, request: message, reply: reply)
            }
            guard !isClosed else { return }
            if xpc_get_type(reply) != iGhostVTXPC.typeDictionary || !frames.send(.reply, tag: tag, object: reply) {
                self.reply(.operationFailed, tag: tag, message: "The terminal helper on the host did not answer.")
            }
        }
    }

    private func daemonEvent(_ event: xpc_object_t) {
        if xpc_get_type(event) == iGhostVTXPC.typeError {
            // The daemon cut this peer or restarted; the device reconnects
            // and reattaches, as the app does locally.
            heldSessions.removeAll()
            if isLingering {
                endLinger()
            } else if !isClosed {
                close(reason: "daemon connection ended")
            }
            return
        }
        // A session this peer no longer holds: taken by another, or ended.
        let kind = xpc_dictionary_get_uint64(event, iGhostVTWireKey.event)
        if kind == iGhostVTEvent.sessionTaken.rawValue || kind == iGhostVTEvent.sessionExit.rawValue {
            heldSessions.remove(xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID))
            if isLingering, heldSessions.isEmpty {
                endLinger()
            }
        }
        guard !isClosed else { return }
        frames.send(.event, tag: 0, object: event)
    }

    /// Output the device has not said it received: everything the path
    /// holds, the TCP buffers on both sides of a relay included, which
    /// `pending` (what the network stack has not taken yet) cannot see.
    private var inFlightByteCount: UInt64 {
        guard let received = deviceReceivedByteCount else { return 0 }
        // A receipt is never ahead of what was sent; compare, never trust.
        return frames.sentByteCount > received ? frames.sentByteCount - received : 0
    }

    private func updateDaemonPause(pending: Int) {
        // Sends still complete after the link closed, and with no receipt
        // coming any more the window would suspend a lingering peer again
        // — which then drains nothing, and the proxy cuts it before its
        // device can come back. `closed` already resumed it.
        guard !isClosed, let daemon else { return }
        let inFlight = inFlightByteCount
        if !isDaemonSuspended,
           pending > Self.pauseAboveByteCount || inFlight > RemoteAccess.linkWindowByteCount
        {
            isDaemonSuspended = true
            xpc_connection_suspend(daemon)
            scheduleTrickle()
        } else if isDaemonSuspended, pending < Self.resumeBelowByteCount,
                  inFlight < RemoteAccess.linkWindowByteCount - RemoteAccess.linkReceiptByteCount
        {
            isDaemonSuspended = false
            xpc_connection_resume(daemon)
        }
    }

    private func scheduleTrickle() {
        trickleGeneration += 1
        let generation = trickleGeneration
        service.queue.asyncAfter(deadline: .now() + Self.trickleInterval) { [weak self] in
            guard let self, generation == trickleGeneration, !isClosed, isDaemonSuspended, let daemon,
                  frames.pendingByteCount < Self.trickleCeilingByteCount
            else { return }
            // The next message raises `pending` past the band again, and
            // `updateDaemonPause` suspends — and schedules this — anew.
            isDaemonSuspended = false
            xpc_connection_resume(daemon)
        }
    }

    // MARK: - Pairing

    private func startPairing(_ message: xpc_object_t, tag: UInt64) {
        guard let deviceID = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceID).map({ String(cString: $0) }),
              Self.isValidDeviceID(deviceID),
              let rawName = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceName).map({ String(cString: $0) }),
              let share = RemoteService.data(iGhostVTWireKey.share, in: message)
        else {
            reply(.invalidRequest, tag: tag)
            return close(reason: "malformed pairStart")
        }
        switch service.beginPairing(client: self, deviceID: deviceID, share: share) {
        case let .success((exchange, answer)):
            mode = .pairing(
                deviceID: deviceID,
                deviceName: RemoteAccess.sanitizedName(rawName),
                exchange: exchange,
            )
            xpc_dictionary_set_uint64(answer, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_int64(answer, iGhostVTWireKey.code, iGhostVTReplyCode.success.rawValue)
            frames.send(.reply, tag: tag, object: answer)
            // A pairing that is never finished is over in half a minute.
            service.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, isPairing else { return }
                close(reason: "pairing not finished in time")
            }
        case let .failure(refusal):
            reply(.invalidRequest, tag: tag, message: refusal.message)
            close(reason: "pairing refused")
        }
    }

    private static func isValidDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private func reply(_ code: iGhostVTReplyCode, tag: UInt64, message: String? = nil) {
        guard tag != 0 else { return }
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        if let message {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, message)
        }
        frames.send(.reply, tag: tag, object: reply)
    }
}
