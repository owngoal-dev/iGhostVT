import Darwin
import Dispatch
import XPC

/// A client of the proxy as the supervisor sees it: a peer id, a place to
/// deliver events, and a connection that can be held back or cut.
protocol IOPeer: AnyObject {
    var peerID: UInt64 { get }
    func deliver(event: xpc_object_t)
    /// Stops taking the client's messages until `resume`. Balanced: a
    /// second `suspend` before the `resume` is a no-op, and so is a
    /// `resume` with nothing suspended.
    func suspend()
    func resume()
    func cutConnection(reason: String)
}

/// Owns the `ighostvtd-io` child and the socket to it.
///
/// The proxy exists so that `ighostvtd` — a launchd job under a 6 MB jetsam
/// limit on the device — holds nothing: every PTY, replay buffer, and shell
/// belongs to the child, which launchd never sized. What passes through
/// here is forwarded verbatim (`IOWire`); the one field the supervisor
/// reads is the operation code, to notice a `shutdown`.
///
/// Two things are policed on the way through, because an unbounded queue
/// anywhere in this process is the jetsam all over again:
///
/// - **Output toward a peer** is counted until libxpc reports it sent
///   (`xpc_connection_send_barrier`). Past `pauseAboveByteCount` in flight,
///   the socket is not read — it fills, and the io side stops draining its
///   PTYs, so a shell writing to a client that is not reading blocks the
///   way it would on a real terminal. A peer that stays congested for
///   `peerCongestionGrace` — the app suspended in the background — is cut
///   instead: the app treats that as an interruption and reattaches when
///   it returns, and the shell meanwhile writes into the replay buffer
///   rather than waiting on it. The pause is one decision for the whole
///   socket, so every peer holding output when it happens gets the timer:
///   once paused nothing more is read, and a peer that never crossed its
///   own threshold would otherwise hold the socket shut for good.
/// - **Input toward the child** is what the socket has not taken yet
///   (`IOChannel.pendingByteCount`). A paste arrives as back-to-back
///   messages at mach speed and leaves at the socket's pace, so past
///   `inputPauseAboveByteCount` every peer's connection is suspended —
///   libxpc then holds the messages in the client — and resumed once the
///   child has drained it below `inputResumeBelowByteCount`.
///
/// The child dying fails every pending reply, cuts every peer (their
/// sessions died with the child, and a reconnect is how the app finds out),
/// and respawns it, paced so a crash loop does not become a spin. An exit of
/// 0 after a forwarded `shutdown` is the one exit that is ours to follow.
final class IOSupervisor {
    static let pauseAboveByteCount = 1 << 20
    static let resumeBelowByteCount = 256 * 1024
    static let peerCongestionByteCount = 512 * 1024
    static let inputPauseAboveByteCount = 1 << 20
    static let inputResumeBelowByteCount = 256 * 1024
    /// A variable only so the harness can shorten the wait it tests.
    static var peerCongestionGrace: DispatchTimeInterval = .seconds(10)
    static let respawnDelay: DispatchTimeInterval = .seconds(2)
    /// Apple's `POSIX_SPAWN_CLOEXEC_DEFAULT`, which the Swift overlay does
    /// not surface: every descriptor not named in the file actions is
    /// closed in the child. The socket is the only thing it inherits.
    private static let closeOnExecByDefault: Int16 = 0x4000

    private struct PendingReply {
        var peer: UInt64
        var completion: (xpc_object_t) -> Void
    }

    private let queue: DispatchQueue
    private let executablePath: String

    private var channel: IOChannel?
    private var childPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var exitStatus: Int32?
    private var lastSpawn = DispatchTime(uptimeNanoseconds: 0)
    private var respawnScheduled = false
    private var shutdownRequested = false

    private var peers: [UInt64: IOPeer] = [:]
    private var pending: [UInt64: PendingReply] = [:]
    private var nextTag: UInt64 = 1

    private var inFlight: [UInt64: Int] = [:]
    private var totalInFlight = 0
    private var congestionTimers: [UInt64: DispatchSourceTimer] = [:]
    private(set) var isInputPaused = false

    /// What follows the child's exit 0 after a `shutdown`: the process's
    /// own exit, which the harness replaces to watch for it.
    var onShutdownExit: () -> Void = {
        DaemonFileLog.flush()
        exit(EXIT_SUCCESS)
    }

    init(queue: DispatchQueue, executablePath: String) {
        self.queue = queue
        self.executablePath = executablePath
    }

    var isRunning: Bool {
        channel != nil
    }

    /// The live child's pid, 0 between spawns.
    var childProcessID: pid_t {
        channel == nil ? 0 : childPID
    }

    func start() throws {
        try spawn()
    }

    // MARK: - Peers

    func register(_ peer: IOPeer) {
        peers[peer.peerID] = peer
        if isInputPaused {
            peer.suspend()
        }
    }

    /// The peer's connection is gone. Its sessions stay in the child — a
    /// detach, not a kill — but nothing may be delivered to it any more.
    func peerGone(_ peerID: UInt64) {
        peers.removeValue(forKey: peerID)
        pending = pending.filter { $0.value.peer != peerID }
        if let bytes = inFlight.removeValue(forKey: peerID) {
            totalInFlight -= bytes
        }
        cancelCongestionTimer(for: peerID)
        channel?.send(.peerGone, peer: peerID, tag: 0, object: nil)
        reconsiderReading()
    }

    /// Forwards a client message as-is. `completion` receives the child's
    /// reply — or a reply this proxy composes when the child cannot answer
    /// — and is never called when `wantsReply` is false.
    func forward(
        from peer: IOPeer,
        message: xpc_object_t,
        wantsReply: Bool,
        completion: @escaping (xpc_object_t) -> Void,
    ) {
        guard let channel else {
            if wantsReply {
                completion(Self.composeFailure(.operationFailed, "The terminal helper is restarting. Try again."))
            }
            return
        }
        if xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation) == iGhostVTOperation.shutdown.rawValue {
            shutdownRequested = true
        }
        var tag: UInt64 = 0
        if wantsReply {
            tag = nextTag
            nextTag &+= 1
            pending[tag] = PendingReply(peer: peer.peerID, completion: completion)
        }
        if !channel.send(.request, peer: peer.peerID, tag: tag, object: message), wantsReply {
            pending.removeValue(forKey: tag)
            completion(Self.composeFailure(.invalidRequest, "Unable to reach the terminal helper. Try again."))
        }
    }

    // MARK: - Flow control

    /// `byteCount` of output was handed to libxpc for `peerID`.
    func willSend(_ byteCount: Int, to peerID: UInt64) {
        let held = (inFlight[peerID] ?? 0) + byteCount
        inFlight[peerID] = held
        totalInFlight += byteCount
        if totalInFlight > Self.pauseAboveByteCount {
            channel?.suspendReading()
            for (id, bytes) in inFlight where bytes > 0 && congestionTimers[id] == nil {
                startCongestionTimer(for: id)
            }
        }
        if held >= Self.peerCongestionByteCount, congestionTimers[peerID] == nil {
            startCongestionTimer(for: peerID)
        }
    }

    /// libxpc reports the output sent: the kernel has it, the proxy no
    /// longer does.
    func didSend(_ byteCount: Int, to peerID: UInt64) {
        guard let current = inFlight[peerID] else { return }
        let remaining = max(0, current - byteCount)
        inFlight[peerID] = remaining
        totalInFlight = max(0, totalInFlight - byteCount)
        reconsiderReading()
        // While the socket stays paused, a peer still holding output is
        // part of what holds it; its timer stands until it drains.
        if remaining == 0 || (remaining < Self.peerCongestionByteCount && channel?.isReadSuspended != true) {
            cancelCongestionTimer(for: peerID)
        }
    }

    private func reconsiderReading() {
        if totalInFlight < Self.resumeBelowByteCount {
            channel?.resumeReading()
        }
    }

    /// The mirror of `IOHost.updateOutputPause`, for the other direction.
    private func updateInputPause(pending: Int) {
        if !isInputPaused, pending > Self.inputPauseAboveByteCount {
            isInputPaused = true
            for peer in peers.values {
                peer.suspend()
            }
            DaemonFileLog.log("io not draining input (\(pending) bytes queued), peers suspended")
        } else if isInputPaused, pending < Self.inputResumeBelowByteCount {
            isInputPaused = false
            for peer in peers.values {
                peer.resume()
            }
        }
    }

    private func startCongestionTimer(for peerID: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.peerCongestionGrace)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            cancelCongestionTimer(for: peerID)
            let held = inFlight[peerID] ?? 0
            peers[peerID]?.cutConnection(
                reason: "\(held) bytes of output not taken in \(Self.peerCongestionGrace.seconds)s",
            )
        }
        congestionTimers[peerID] = timer
        timer.activate()
    }

    private func cancelCongestionTimer(for peerID: UInt64) {
        congestionTimers.removeValue(forKey: peerID)?.cancel()
    }

    // MARK: - The child

    private func spawn() throws {
        // The attempt, not the success: pacing keyed on the last child that
        // came up lets a spawn that keeps failing retry without a pause.
        lastSpawn = .now()
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw iGhostVTDaemonError.transportFailure
        }
        let parentEnd = pair[0]
        let childEnd = pair[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // launchd's /dev/null on 0–2, when they are open; a missing one
        // must not fail the spawn.
        for descriptor: Int32 in 0 ... 2 where fcntl(descriptor, F_GETFD) >= 0 {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        posix_spawn_file_actions_adddup2(&actions, childEnd, IOWire.socketDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Self.closeOnExecByDefault)

        let arguments = [executablePath, IOWire.socketArgument, String(IOWire.socketDescriptor)]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &actions, &attributes, argv, environ)
        close(childEnd)
        guard status == 0 else {
            close(parentEnd)
            DaemonFileLog.log("io spawn of \(executablePath) failed: \(String(cString: strerror(status)))")
            throw iGhostVTDaemonError.transportFailure
        }

        childPID = pid
        exitStatus = nil
        let channel = IOChannel(descriptor: parentEnd, queue: queue)
        channel.onFrame = { [weak self] header, payload in
            self?.handleFrame(header, payload: payload)
        }
        channel.onClosed = { [weak self] in
            self?.handleLinkClosed()
        }
        channel.onPendingChange = { [weak self] pending in
            self?.updateInputPause(pending: pending)
        }
        self.channel = channel
        channel.activate()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            self?.reapIfExited()
        }
        self.exitSource = exitSource
        exitSource.activate()
        DaemonFileLog.log("io spawned as pid \(pid) from \(executablePath)")
    }

    private func handleFrame(_ header: IOWire.Header, payload: UnsafeRawBufferPointer) {
        switch header.kind {
        case .reply:
            guard let entry = pending.removeValue(forKey: header.tag) else { return }
            let reply = IOCodec.decode(payload)
                ?? Self.composeFailure(.operationFailed, "The terminal helper sent an unexpected response. Try again.")
            entry.completion(reply)
        case .event:
            guard let peer = peers[header.peer], let event = IOCodec.decode(payload) else { return }
            peer.deliver(event: event)
        case .request, .peerGone:
            DaemonFileLog.log("io sent a \(header.kind) frame, ignored")
        }
    }

    /// The socket to the child is gone, which means the child is — or is
    /// about to be. Everything routed through it is failed or cut here;
    /// what happens next depends on how the child exited.
    private func handleLinkClosed() {
        channel = nil
        exitSource?.cancel()
        exitSource = nil
        for timer in congestionTimers.values {
            timer.cancel()
        }
        congestionTimers.removeAll()
        inFlight.removeAll()
        totalInFlight = 0

        let unanswered = pending
        pending.removeAll()
        for entry in unanswered.values {
            entry.completion(Self.composeFailure(.operationFailed, "The terminal helper restarted. Try again."))
        }
        for peer in Array(peers.values) {
            peer.cutConnection(reason: "io link closed")
        }
        peers.removeAll()
        isInputPaused = false
        pollExitStatus()
    }

    private func pollExitStatus(attempt: Int = 0) {
        reapIfExited()
        guard let exitStatus else {
            guard attempt < 100 else {
                DaemonFileLog.log("io pid \(childPID) closed its link but is not reapable; respawning anyway")
                scheduleRespawn()
                return
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                self?.pollExitStatus(attempt: attempt + 1)
            }
            return
        }
        if shutdownRequested, exitStatus == 0 {
            DaemonFileLog.log("io exited after shutdown, exiting")
            onShutdownExit()
            return
        }
        DaemonFileLog.log("io pid \(childPID) exited with status \(exitStatus), respawning")
        scheduleRespawn()
    }

    private func reapIfExited() {
        guard childPID > 0, exitStatus == nil else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        guard result != 0 else {
            return
        }
        exitStatus = if result < 0 {
            -1
        } else if status & 0x7F == 0 {
            (status >> 8) & 0xFF
        } else {
            128 + (status & 0x7F)
        }
        // The child is gone whether or not its socket has reported it yet;
        // the link handler is the one place that decides what to do.
        channel?.close()
    }

    private func scheduleRespawn() {
        guard !respawnScheduled else { return }
        respawnScheduled = true
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSpawn.uptimeNanoseconds
        let delay: DispatchTimeInterval = elapsed < UInt64(Self.respawnDelay.nanoseconds)
            ? Self.respawnDelay
            : .milliseconds(0)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            respawnScheduled = false
            do {
                try spawn()
            } catch {
                scheduleRespawn()
            }
        }
    }

    private static func composeFailure(_ code: iGhostVTReplyCode, _ message: String) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, message)
        return reply
    }
}

private extension DispatchTimeInterval {
    var nanoseconds: Int {
        switch self {
        case let .seconds(value): value * 1_000_000_000
        case let .milliseconds(value): value * 1_000_000
        case let .microseconds(value): value * 1000
        case let .nanoseconds(value): value
        case .never: Int.max
        @unknown default: Int.max
        }
    }

    var seconds: Int {
        nanoseconds / 1_000_000_000
    }
}
