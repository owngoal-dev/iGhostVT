import Darwin
import Dispatch
import XPC

/// The io side of the proxy link: turns frames from `ighostvtd` into peer
/// requests and peer output into frames.
///
/// Peers are known by the id the proxy stamps on each frame and are made on
/// first sight; `peerGone` retires one. When the proxy stops taking output
/// (a client not reading), the backlog here is what grows — bounded by
/// pausing every PTY past `pauseAboveByteCount`, so a shell then blocks on
/// its write the way it would on a real terminal.
final class IOHost {
    static let pauseAboveByteCount = 2 << 20
    static let resumeBelowByteCount = 256 * 1024

    private let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.io.control",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let channel: IOChannel
    private lazy var registry = SessionRegistry(queue: queue)
    private var peers: [UInt64: PeerSession] = [:]
    private var isOutputPaused = false

    init(descriptor: Int32) {
        channel = IOChannel(descriptor: descriptor, queue: queue)
    }

    func start() {
        channel.onFrame = { [weak self] header, payload in
            self?.handle(header, payload: payload)
        }
        channel.onClosed = {
            // The proxy is gone and nothing can reach the sessions again;
            // the PTY masters close with this process and the shells get
            // their SIGHUP. Not a success: that exit is reserved for
            // `shutdown`.
            DaemonFileLog.log("proxy link closed, exiting")
            DaemonFileLog.flush()
            exit(EXIT_FAILURE)
        }
        channel.onPendingChange = { [weak self] pending in
            self?.updateOutputPause(pending: pending)
        }
        channel.activate()
        DaemonFileLog.log("io serving, uid \(getuid()) euid \(geteuid()), parent \(getppid())")
    }

    // MARK: - Toward the proxy

    func send(_ kind: IOWire.Kind, peer: UInt64, tag: UInt64, message: xpc_object_t) {
        if !channel.send(kind, peer: peer, tag: tag, object: message) {
            DaemonFileLog.log("peer \(peer): a \(kind) frame could not be encoded, dropped")
        }
    }

    /// The peer said goodbye, or the proxy said it is gone.
    func removePeer(_ peerID: UInt64) {
        peers.removeValue(forKey: peerID)?.invalidate()
    }

    /// `shutdown` answered with nothing held: the reply goes out whole,
    /// then the process ends — the exit the proxy follows.
    func exitAfterShutdown() {
        DaemonFileLog.log("shutdown with nothing held, exiting")
        channel.flushBlocking()
        DaemonFileLog.flush()
        exit(EXIT_SUCCESS)
    }

    // MARK: - From the proxy

    private func handle(_ header: IOWire.Header, payload: UnsafeRawBufferPointer) {
        switch header.kind {
        case .request:
            guard let message = IOCodec.decode(payload) else {
                DaemonFileLog.log("peer \(header.peer): unreadable request, dropped")
                if header.tag != 0 {
                    let reply = xpc_dictionary_create(nil, nil, 0)
                    xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
                    xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, iGhostVTReplyCode.invalidRequest.rawValue)
                    send(.reply, peer: header.peer, tag: header.tag, message: reply)
                }
                return
            }
            let peer = peers[header.peer] ?? makePeer(header.peer)
            peer.handle(message, tag: header.tag)
        case .peerGone:
            removePeer(header.peer)
        case .reply, .event:
            DaemonFileLog.log("proxy sent a \(header.kind) frame, ignored")
        }
    }

    private func makePeer(_ peerID: UInt64) -> PeerSession {
        let peer = PeerSession(peerID: peerID, queue: queue, registry: registry, host: self)
        peers[peerID] = peer
        return peer
    }

    private func updateOutputPause(pending: Int) {
        if !isOutputPaused, pending > Self.pauseAboveByteCount {
            isOutputPaused = true
            registry.setOutputPaused(true)
            DaemonFileLog.log("proxy not draining (\(pending) bytes queued), sessions paused")
        } else if isOutputPaused, pending < Self.resumeBelowByteCount {
            isOutputPaused = false
            registry.setOutputPaused(false)
            DaemonFileLog.log("proxy draining again, sessions resumed")
        }
    }
}
