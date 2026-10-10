import Dispatch
import Foundation
import Network
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

/// What carries the daemon protocol for a transport: the local daemon's
/// XPC connection, or a TLS link to another device's `ighostvtd-remote`.
/// Both carry the same dictionaries, so `XPCDaemonTransport` — opening,
/// attaching, replay, input, resizing — is the same for a remote tab.
///
/// Everything is delivered on the queue the link was made with: replies,
/// events, and the one `lost`. A link that dies answers every reply still
/// outstanding with an empty dictionary, which reads as `operationFailed`.
protocol DaemonLink: AnyObject, Sendable {
    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void)
    func send(_ message: xpc_object_t)
    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void)
    func cancel()
}

enum DaemonLinkEvent: @unchecked Sendable {
    case message(xpc_object_t)
    /// The link died out from under its owner. Not delivered for `cancel`.
    case lost
}

/// Where a transport's daemon is.
enum DaemonEndpoint: Sendable, Equatable {
    case local
    case remote(hostID: String)

    var isRemote: Bool {
        if case .remote = self {
            return true
        }
        return false
    }

    /// A fresh link to the endpoint, `nil` when there is no way to reach it
    /// at all (no daemon service, a host that is not paired).
    func makeLink(queue: DispatchQueue) -> DaemonLink? {
        switch self {
        case .local:
            XPCDaemonLink(queue: queue)
        case let .remote(hostID):
            RemoteDaemonLink(hostID: hostID, queue: queue)
        }
    }
}

// MARK: - Local

final class XPCDaemonLink: DaemonLink, @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isCancelled = false

    init?(queue: DispatchQueue) {
        // Ghost Remote has no daemon of its own, and its sandbox would
        // refuse the lookup anyway.
        guard !AppEdition.isRemoteOnly,
              let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else { return nil }
        self.connection = connection
        self.queue = queue
    }

    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void) {
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool {
                if xpc_get_type(event) == iGhostVTXPC.typeError {
                    guard let self, !self.lock.withLock({ self.isCancelled }) else { return }
                    handler(.lost)
                } else {
                    handler(.message(event))
                }
            }
        }
        xpc_connection_activate(connection)
    }

    func send(_ message: xpc_object_t) {
        xpc_connection_send_message(connection, message)
    }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        xpc_connection_send_message_with_reply(connection, message, queue, reply)
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        xpc_connection_cancel(connection)
    }
}

// MARK: - Remote

/// The daemon of a paired device, through its `ighostvtd-remote`.
///
/// TLS with this device's key for that host — so only the host that holds
/// the key completes the handshake — and the first `hello` gains the
/// device's id and its proof over the session's exporter secret, which is
/// how the host knows which device this is (`RemoteAccess`). Everything
/// else is the local protocol, framed (`RemoteFrameConnection`).
///
/// The host is reached one of two ways: straight, at the address Bonjour
/// gives or the one it last answered at, or through the relay
/// (`Relay/PROTOCOL.md`), which splices the same TLS to it by SNI. With a
/// relay configured both are tried, the direct one first and the relay a
/// moment later — sooner when the direct one fails outright — and the
/// first to finish its handshake is the link; the other is dropped. The
/// path is not changed under a live link: the next connection tries again,
/// and is back on the local network as soon as that answers first.
final class RemoteDaemonLink: DaemonLink, @unchecked Sendable {
    private let hostID: String
    private let host: PairedRemoteHost
    private let queue: DispatchQueue
    private var frames: RemoteFrameConnection?
    private var winningPath: Path?
    private var handler: (@Sendable (DaemonLinkEvent) -> Void)?
    private var pendingReplies: [UInt64: @Sendable (xpc_object_t) -> Void] = [:]
    private var nextTag: UInt64 = 1
    /// Sent before TLS was up; they leave, in order, once it is.
    private var queuedBeforeReady: [(tag: UInt64, message: xpc_object_t)] = []
    private var isReady = false
    private var isFinished = false
    /// The host is known to run another iGhostVT: nothing is dialled, and
    /// the hello is answered here with what the host would have said.
    private var refusedVersion: String?

    private enum Path {
        case direct(NWEndpoint)
        case relay(RelayConfiguration)

        var isRelay: Bool {
            if case .relay = self {
                return true
            }
            return false
        }
    }

    /// When the host last sent anything, for the relayed link's heartbeat
    /// and the question asked when the network changes.
    private var lastHeard = Date()
    /// When this side last sent anything. The host drops a relayed device
    /// it has not heard from in `RemoteAccess.deviceSilenceLimit`, and a
    /// download — `sz`, a long `cat` — is all host to device: the app hears
    /// plenty and says nothing, so the quiet it has to break is its own.
    private var lastSent = Date()
    private var pathObserver: NSObjectProtocol?

    /// Connections still racing, and the paths not tried yet.
    private var attempts: [RemoteFrameConnection] = []
    private var untried: [(path: Path, delay: TimeInterval)] = []
    private var launchGeneration = 0

    init?(hostID: String, queue: DispatchQueue) {
        guard let host = PairedRemoteHostStore.host(id: hostID) else { return nil }
        self.hostID = hostID
        self.host = host
        self.queue = queue
    }

    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void) {
        queue.async { [self] in
            self.handler = handler
            if let theirs = RemoteHostDirectory.mismatchedVersion(ofHostID: hostID) {
                AppLog.info(.transport, "remote host \(hostID) runs iGhostVT \(theirs), not \(RemoteAccess.appVersion)")
                refusedVersion = theirs
                return
            }
            untried = Self.plan(hostID: hostID, host: host)
            guard !untried.isEmpty else {
                AppLog.warning(.transport, "remote host \(hostID) has no known address and no relay")
                finish(lost: true)
                return
            }
            launchNext()
        }
    }

    /// Which paths, in which order, and how long each waits for the one
    /// before it. Bonjour seeing the host makes the direct path all but
    /// certain, so the relay waits a second (it can still see a host that
    /// left, or an access point that keeps clients apart); a remembered
    /// address is a guess, and the relay waits 300 ms.
    ///
    /// The relay goes first only while the direct path is known not to
    /// answer — it failed in the last few minutes — so the list and the
    /// menus, which connect every half minute away from home, do not dial
    /// a dead address every time. Never because the relay merely won: that
    /// was remembered once, and a relay that went first kept winning, kept
    /// the memory fresh, and held a host on the local network behind the
    /// relay for as long as anything connected. And never while Bonjour
    /// sees the host here.
    private static func plan(hostID: String, host: PairedRemoteHost) -> [(path: Path, delay: TimeInterval)] {
        #if DEBUG
            // `Scripts/remote-lab`: a simulator shares the Mac's network,
            // where Bonjour always sees the host, so a bad relay path is
            // only ever tested with the direct one taken away.
            if UserDefaults.standard.bool(forKey: "RemoteLab.relayOnly") {
                return RelayConfigurationStore.current.map { [(.relay($0), 0)] } ?? []
            }
        #endif
        let bonjour = RemoteHostDirectory.endpoint(forHostID: hostID)
        var paths: [(path: Path, delay: TimeInterval)] = []
        if let direct = bonjour ?? host.lastEndpoint {
            paths.append((.direct(direct), 0))
        }
        if let relay = RelayConfigurationStore.current {
            paths.append((.relay(relay), paths.isEmpty ? 0 : (bonjour != nil ? 1 : 0.3)))
        }
        if bonjour == nil, paths.count == 2, RemotePathMemory.directFailedRecently(forHostID: hostID) {
            paths = [(paths[1].path, 0), (paths[0].path, 1)]
        }
        return paths
    }

    private func launchNext() {
        guard !isFinished, frames == nil, !untried.isEmpty else { return }
        let (path, _) = untried.removeFirst()
        launchGeneration += 1
        let frames = RemoteFrameConnection(connection: makeConnection(path), queue: queue)
        frames.onReady = { [weak self, weak frames] in
            guard let self, let frames else { return }
            won(frames, path: path)
        }
        frames.onFrame = { [weak self] header, object in self?.received(header, object) }
        frames.onClosed = { [weak self, weak frames] reason in
            guard let self, let frames else { return }
            attemptClosed(frames, path: path, reason: reason)
        }
        attempts.append(frames)
        frames.start()
        guard let next = untried.first else { return }
        let generation = launchGeneration
        queue.asyncAfter(deadline: .now() + next.delay) { [weak self] in
            guard let self, generation == launchGeneration else { return }
            launchNext()
        }
    }

    private func makeConnection(_ path: Path) -> NWConnection {
        let parameters = RemoteTLS.parameters(
            keys: [RemoteTLS.Key(identity: Data(host.deviceID.utf8), secret: host.deviceKey)],
            serverName: hostID,
        )
        switch path {
        case let .direct(endpoint):
            return NWConnection(to: endpoint, using: parameters)
        case let .relay(configuration):
            return NWConnection(to: configuration.endpoint, using: parameters)
        }
    }

    private func won(_ winner: RemoteFrameConnection, path: Path) {
        guard frames == nil, !isFinished else { return }
        frames = winner
        winningPath = path
        untried.removeAll()
        for attempt in attempts where attempt !== winner {
            attempt.onClosed = nil
            attempt.onFrame = nil
            attempt.close(reason: "another path answered first")
        }
        attempts.removeAll()
        if !path.isRelay {
            RemotePathMemory.noteDirectAnswered(forHostID: hostID)
        }
        AppLog.info(.transport, "remote link to \(host.name) \(path.isRelay ? "through the relay" : "direct")")
        ready()
        lastHeard = Date()
        heartbeat()
        pathObserver = NotificationCenter.default.addObserver(
            forName: NetworkPathWatcher.pathDidChange,
            object: nil,
            queue: nil,
        ) { [weak self] note in
            let isSatisfied = note.userInfo?[NetworkPathWatcher.isSatisfiedKey] as? Bool ?? true
            self?.queue.async { self?.networkChanged(isSatisfied: isSatisfied) }
        }
    }

    private func attemptClosed(_ attempt: RemoteFrameConnection, path: Path, reason: String) {
        if attempt === frames {
            AppLog.info(.transport, "remote link to \(host.name) closed: \(reason)")
            finish(lost: true)
            return
        }
        attempts.removeAll { $0 === attempt }
        AppLog.info(.transport, "remote link to \(host.name) \(path.isRelay ? "through the relay" : "direct") failed: \(reason)")
        // Only a direct attempt that failed on its own counts: one that lost
        // the race was closed without this callback.
        if !path.isRelay {
            RemotePathMemory.noteDirectFailed(forHostID: hostID)
        }
        guard frames == nil else { return }
        if !untried.isEmpty {
            // No point waiting out the head start of a path that is gone.
            if attempts.isEmpty {
                launchNext()
            }
        } else if attempts.isEmpty {
            finish(lost: true)
        }
    }

    func send(_ message: xpc_object_t) {
        queue.async { [self] in
            enqueue(message, tag: 0)
        }
    }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        queue.async { [self] in
            if let refusedVersion {
                reply(Self.versionRefusal(theirs: refusedVersion))
                return
            }
            guard !isFinished else {
                reply(xpc_dictionary_create(nil, nil, 0))
                return
            }
            let tag = nextTag
            nextTag &+= 1
            pendingReplies[tag] = reply
            enqueue(message, tag: tag)
        }
    }

    /// What a host of another version answers a hello with.
    private static func versionRefusal(theirs: String) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, iGhostVTReplyCode.unsupportedVersion.rawValue)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.appVersion, theirs)
        return reply
    }

    func cancel() {
        queue.async { [self] in
            finish(lost: false)
        }
    }

    private func enqueue(_ message: xpc_object_t, tag: UInt64) {
        guard !isFinished, refusedVersion == nil else { return }
        guard isReady, let frames else {
            queuedBeforeReady.append((tag, message))
            return
        }
        transmit(message, tag: tag, over: frames)
    }

    private func ready() {
        guard let frames else { return }
        isReady = true
        PairedRemoteHostStore.noteReached(frames.connection, forHostID: hostID, viaRelay: winningPath?.isRelay == true)
        let queued = queuedBeforeReady
        queuedBeforeReady.removeAll()
        for item in queued {
            transmit(item.message, tag: item.tag, over: frames)
        }
    }

    private func transmit(_ message: xpc_object_t, tag: UInt64, over frames: RemoteFrameConnection) {
        lastSent = Date()
        if xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation) == iGhostVTOperation.hello.rawValue {
            guard let exporter = RemoteTLS.exporterSecret(of: frames.connection) else {
                frames.close(reason: "no exporter secret")
                return
            }
            let proof = RemoteDeviceProof.make(key: host.deviceKey, exporterSecret: exporter, deviceID: host.deviceID)
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceID, host.deviceID)
            // The name it goes by now, so the host's list follows a rename.
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceName, RemoteDeviceIdentity.deviceName)
            xpc_dictionary_set_string(message, iGhostVTWireKey.appVersion, RemoteAccess.wireVersion)
            proof.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.confirmation, base, buffer.count)
                }
            }
        }
        if !frames.send(.request, tag: tag, object: message), tag != 0 {
            pendingReplies.removeValue(forKey: tag)?(xpc_dictionary_create(nil, nil, 0))
        }
    }

    /// A link is alive only if the host answers across it: every box on
    /// the way — a relay, a NAT — may keep its own TCP leg up for a peer
    /// that is gone. A quiet link is pinged; one the host has not answered
    /// on for `RemoteAccess.linkReplyLimit` is given up, and its owner
    /// reconnects as after any other loss. Quiet in *either* direction:
    /// the host judges the device by what it sends, so a link that only
    /// receives is pinged as well.
    private func heartbeat() {
        queue.asyncAfter(deadline: .now() + RemoteAccess.linkPingInterval / 3) { [weak self] in
            guard let self, !isFinished, let frames else { return }
            let quiet = Date().timeIntervalSince(lastHeard)
            if quiet > RemoteAccess.linkReplyLimit {
                AppLog.info(.transport, "remote link to \(host.name): nothing from the host in \(Int(quiet)) s")
                finish(lost: true)
                return
            }
            let silent = Date().timeIntervalSince(lastSent)
            if quiet > RemoteAccess.linkPingInterval || silent > RemoteAccess.linkPingInterval, isReady {
                ping(over: frames)
            }
            heartbeat()
        }
    }

    /// The network went away or moved to other interfaces, and a link on
    /// the old one is most likely dead — but TCP would take half a minute
    /// to say so, with the tab sitting on a frozen screen meanwhile. With
    /// no network at all it is given up at once; otherwise the host is
    /// asked, and a link it does not answer on within
    /// `RemoteAccess.pathChangeReplyLimit` is given up. Either way the
    /// owner reconnects as after any other loss, over the network there is
    /// now. Every host on the release line answers the ping, direct or
    /// relayed.
    private func networkChanged(isSatisfied: Bool) {
        guard !isFinished, isReady, let frames else { return }
        guard isSatisfied else {
            AppLog.info(.transport, "remote link to \(host.name): the network went away")
            finish(lost: true)
            return
        }
        let asked = Date()
        ping(over: frames)
        queue.asyncAfter(deadline: .now() + RemoteAccess.pathChangeReplyLimit) { [weak self] in
            guard let self, !isFinished, self.frames === frames, lastHeard < asked else { return }
            AppLog.info(.transport, "remote link to \(host.name): no answer after the network changed")
            finish(lost: true)
        }
    }

    private func ping(over frames: RemoteFrameConnection) {
        let ping = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(ping, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(ping, iGhostVTWireKey.operation, iGhostVTOperation.ping.rawValue)
        let tag = nextTag
        nextTag &+= 1
        // The answer is only worth having arrived.
        pendingReplies[tag] = { _ in }
        transmit(ping, tag: tag, over: frames)
    }

    private func received(_ header: IOWire.Header, _ object: xpc_object_t) {
        lastHeard = Date()
        switch header.kind {
        case .reply:
            pendingReplies.removeValue(forKey: header.tag)?(object)
        case .event:
            handler?(.message(object))
        case .request, .peerGone:
            break
        }
    }

    private func finish(lost: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if let pathObserver {
            NotificationCenter.default.removeObserver(pathObserver)
            self.pathObserver = nil
        }
        untried.removeAll()
        for attempt in attempts where attempt !== frames {
            attempt.onClosed = nil
            attempt.close(reason: "link finished")
        }
        attempts.removeAll()
        // A cancel lets the last frames leave first: the owner's close or
        // detach was sent just before it.
        if lost {
            frames?.close(reason: "lost")
        } else {
            frames?.onClosed = nil
            frames?.closeWhenFlushed()
        }
        frames = nil
        queuedBeforeReady.removeAll()
        let unanswered = pendingReplies
        pendingReplies.removeAll()
        for reply in unanswered.values {
            reply(xpc_dictionary_create(nil, nil, 0))
        }
        let handler = handler
        self.handler = nil
        if lost {
            handler?(.lost)
        }
    }
}

/// When the direct path to each host last failed, for a few minutes: a link
/// opened soon after puts the relay first instead of waiting on an address
/// that did not answer. Only a failure sets it and a direct link clears it,
/// so it lapses on its own — a relay that keeps winning is no evidence the
/// local network is gone.
enum RemotePathMemory {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var directFailures: [String: Date] = [:]
    private static let lifetime: TimeInterval = 300

    static func noteDirectFailed(forHostID id: String) {
        lock.withLock { directFailures[id] = Date() }
    }

    static func noteDirectAnswered(forHostID id: String) {
        lock.withLock { _ = directFailures.removeValue(forKey: id) }
    }

    static func directFailedRecently(forHostID id: String) -> Bool {
        lock.withLock {
            guard let failed = directFailures[id] else { return false }
            return Date().timeIntervalSince(failed) < lifetime
        }
    }
}
