import Darwin
import Dispatch
import os
import XPC

/// Mach service listener.
///
/// Accepts several peers at once (an iPad can have more than one app window)
/// and never exits on its own initiative. It used to idle-exit after thirty
/// seconds with no peers and no sessions, leaving launchd to demand-launch it
/// again.
///
/// Demand launch does work — killing the daemon and reopening the app brings
/// it back through `ipc (mach)`, verified on device. Exiting on the daemon's
/// own judgement is still wrong. The check and the exit cannot be made atomic
/// against launchd routing a new connection, so a client that arrives in that
/// window watches the service disappear instead of getting a session, and it
/// is exactly the window the app is most likely to be in: the last shell
/// exiting is what empties the registry, and reaching for a new tab is what
/// the user does next. Staying resident costs a few MB and removes the whole
/// class of failure. launchd's `KeepAlive` covers what remains, which is a
/// crash.
///
/// The one exit is the one a client asks for (`shutdown`, answered by
/// `ighostvtd-io` once it holds nothing, and followed by `IOSupervisor` when
/// the child then exits 0): the quitting app, once it has closed its tabs
/// and seen the registry empty. Whether the exit sticks is the plist's
/// business — the Mac agent's `KeepAlive` restarts only an unsuccessful exit
/// and the mach service demand-launches it when the app returns; the device
/// daemon is kept alive unconditionally and would come straight back, so the
/// app never asks there.
///
/// This process holds no session: it is the jetsam-limited launchd job, and
/// everything with a buffer lives in the child (`IOSupervisor`).
final class DaemonServer {
    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.control",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let authenticator = PeerAuthenticator()
    private lazy var supervisor = IOSupervisor(
        queue: controlQueue,
        executablePath: Self.ioExecutablePath(),
    )

    private var listener: xpc_connection_t?
    private var peers: [UInt64: PeerRelay] = [:]
    private var nextPeerID: UInt64 = 1

    /// `ighostvtd-io` beside this executable: `/usr/libexec` on the device,
    /// `Contents/MacOS` in the Mac bundle, the same DerivedData products
    /// directory for the harness.
    private static func ioExecutablePath() -> String {
        guard let own = RuntimeEnvironment.currentExecutablePath(),
              let slash = own.lastIndex(of: "/")
        else { return IOWire.executableName }
        return String(own[...slash]) + IOWire.executableName
    }

    func start() throws {
        guard listener == nil else { return }
        if !supervisor.isRunning {
            try supervisor.start()
        }
        guard let listener = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceListener(
                $0,
                controlQueue,
                PrivateSystemConstant.machServiceListener,
            )
        }) else {
            throw iGhostVTDaemonError.transportFailure
        }
        self.listener = listener

        xpc_connection_set_event_handler(listener) { [weak self] event in
            autoreleasepool {
                self?.accept(event)
            }
        }
        xpc_connection_activate(listener)
        DaemonLog.server.info(
            "listening on \(iGhostVTProtocol.serviceName, privacy: .public), pid \(getpid())",
        )
        DaemonFileLog.log(
            "listening on \(iGhostVTProtocol.serviceName), uid \(getuid()) euid \(geteuid())",
        )
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == iGhostVTXPC.typeConnection else { return }
        guard let clientPID = authenticator.authenticate(event) else {
            DaemonFileLog.log("peer rejected, connection canceled")
            xpc_connection_cancel(event)
            return
        }

        let peerID = nextPeerID
        nextPeerID &+= 1
        let peer = PeerRelay(
            peerID: peerID,
            connection: event,
            clientPID: clientPID,
            queue: controlQueue,
            supervisor: supervisor,
        ) { [weak self] peer in
            self?.peerInvalidated(peer)
        }
        peers[peerID] = peer
        peer.activate()
        DaemonLog.server.info("peer \(clientPID) connected as \(peerID), \(peers.count) peer(s)")
        DaemonFileLog.log("peer \(clientPID) connected as peer \(peerID), \(peers.count) peer(s)")
    }

    /// The peer went away. Its sessions stay: detaching is not closing, and
    /// the next launch reattaches to them.
    private func peerInvalidated(_ peer: PeerRelay) {
        peers.removeValue(forKey: peer.peerID)
        DaemonLog.server.info("peer gone, \(peers.count) peer(s) remain")
        DaemonFileLog.log("peer \(peer.peerID) gone, \(peers.count) peer(s) remain")
    }
}
