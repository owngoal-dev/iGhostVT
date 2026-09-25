import Darwin
import Dispatch
import XPC

/// One authenticated client connection, relayed to `ighostvtd-io`.
///
/// Holds no session state and reads no request: whatever the client sends
/// goes to the child with this peer's id, whatever comes back for this id
/// goes to the client. The one exception is `goodbye`, after which the
/// connection is the proxy's to close.
final class PeerRelay: IOPeer {
    let peerID: UInt64
    private let connection: xpc_connection_t
    private let clientPID: Int32
    private let queue: DispatchQueue
    private let supervisor: IOSupervisor
    private let onInvalidate: (PeerRelay) -> Void
    private var isValid = true
    private var isSuspended = false

    init(
        peerID: UInt64,
        connection: xpc_connection_t,
        clientPID: Int32,
        queue: DispatchQueue,
        supervisor: IOSupervisor,
        onInvalidate: @escaping (PeerRelay) -> Void,
    ) {
        self.peerID = peerID
        self.connection = connection
        self.clientPID = clientPID
        self.queue = queue
        self.supervisor = supervisor
        self.onInvalidate = onInvalidate
    }

    func activate() {
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool {
                self?.handle(event)
            }
        }
        xpc_connection_activate(connection)
        // After activation, so a suspend the supervisor applies on
        // registration lands on an active connection; events reach `handle`
        // on this queue, which is the one this runs on, so none arrive
        // before the peer is registered.
        supervisor.register(self)
    }

    private func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == iGhostVTXPC.typeError {
            invalidate()
            return
        }
        guard type == iGhostVTXPC.typeDictionary, isValid else { return }

        let reply = xpc_dictionary_create_reply(event)
        let isGoodbye = xpc_dictionary_get_uint64(event, iGhostVTWireKey.operation)
            == iGhostVTOperation.goodbye.rawValue
        supervisor.forward(from: self, message: event, wantsReply: reply != nil) { [weak self] result in
            guard let self, isValid else { return }
            if let reply {
                IOCodec.copyEntries(from: result, into: reply)
                xpc_connection_send_message(connection, reply)
            }
            if isGoodbye {
                queue.async { [weak self] in self?.invalidate() }
            }
        }
        if isGoodbye, reply == nil {
            queue.async { [weak self] in self?.invalidate() }
        }
    }

    // MARK: - IOPeer

    func deliver(event: xpc_object_t) {
        guard isValid else { return }
        var byteCount = 0
        if xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue {
            var length = 0
            if xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length) != nil {
                byteCount = length
            }
        }
        xpc_connection_send_message(connection, event)
        guard byteCount > 0 else { return }
        // Counted until libxpc has handed it to the kernel; the barrier
        // runs on the connection's target queue, which is ours.
        supervisor.willSend(byteCount, to: peerID)
        let peerID = peerID
        let supervisor = supervisor
        xpc_connection_send_barrier(connection) {
            supervisor.didSend(byteCount, to: peerID)
        }
    }

    func suspend() {
        guard isValid, !isSuspended else { return }
        isSuspended = true
        xpc_connection_suspend(connection)
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        xpc_connection_resume(connection)
    }

    func cutConnection(reason: String) {
        guard isValid else { return }
        DaemonFileLog.log("peer \(peerID) (pid \(clientPID)) cut: \(reason)")
        invalidate()
    }

    private func invalidate() {
        guard isValid else { return }
        isValid = false
        // libxpc requires every suspend balanced before the connection's
        // last release; whatever it delivers meanwhile is dropped above.
        resume()
        supervisor.peerGone(peerID)
        xpc_connection_cancel(connection)
        onInvalidate(self)
    }
}
