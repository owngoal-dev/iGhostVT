import Darwin
import Dispatch
import Foundation
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

/// Terminal I/O carried by `ighostvtd` — this device's, over XPC, or a
/// paired device's, over remote access (`DaemonEndpoint`, `DaemonLink`).
///
/// The app cannot spawn anything: it asks the daemon to open a session and
/// then only pushes keystrokes and grid sizes. Because the daemon owns the
/// session, `connect()` prefers reattaching to a session this transport
/// already had — relaunching the app restores the running shell, replayed
/// output and all, rather than starting a fresh one.
final class XPCDaemonTransport: TerminalTransport, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.client.xpc",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let lock = NSLock()
    /// Where the daemon is. Fixed for the transport's life.
    let endpoint: DaemonEndpoint
    private var connection: DaemonLink?
    private var sessionID: UInt64?
    /// The grid the host reported most recently, so an open spawns the shell
    /// at the size the surface has rather than the protocol default. Confined
    /// to `queue`, as is every size decision below: `updateViewport` hops
    /// there, and the open/attach replies arrive there.
    private var latestViewport: (columns: Int, rows: Int)?
    /// The grid the daemon's session is known to hold — what the open spawned
    /// at, what the attach reply said, or the last resize sent. A repeat is
    /// dropped: the host re-sends its newest size on every connect (and one
    /// that does not suppress them reports again on pixel-only changes), and
    /// each would otherwise cost a message for a `TIOCSWINSZ` the kernel
    /// treats as a no-op.
    /// Forgotten with the connection, since a new one may reach a session
    /// this transport never sized.
    private var appliedViewport: (columns: Int, rows: Int)?
    private var _onEvent: (@Sendable (TerminalTransportEvent) -> Void)?
    private var _onSessionExit: (@Sendable (UInt64, Int32) -> Void)?

    /// Session to reattach to, if this transport is resuming a known one.
    private var resumeSessionID: UInt64?
    /// The attach of this connect takes the session from whoever holds
    /// it (`connect(takingOver:)`). Confined to `queue`.
    private var takesOver = false

    /// An end the host asked for while the connection was still negotiating
    /// — between `establish` and the open or attach reply. The request is
    /// with the daemon by then and a cancel cannot recall it: the daemon
    /// would spawn the shell (or attach the resumed one) under a peer that
    /// is gone, and peer loss is a detach, never a kill, so the tab the user
    /// closed lived on as an unattached session. The reply handler carries
    /// the end out instead. A close outranks a detach. Confined to `queue`.
    private enum DeferredEnd { case detach, close }
    private var deferredEnd: DeferredEnd?
    /// This transport, held by itself while an end is deferred: the owner
    /// drops its reference the moment it asks (see the note above
    /// `connect`), and the reply handlers hold `self` weakly so an abandoned
    /// transport can still deinit — the deferred end has to outlive both
    /// until the reply lands. Released by `dropConnection`, which every
    /// ending passes through.
    private var retainedForDeferredEnd: XPCDaemonTransport?

    /// Absolute path of the shell to run, or `nil` to let the daemon pick.
    /// The daemon validates it (absolute, existing, executable) and rejects
    /// anything else — the app cannot talk it into running arbitrary bytes.
    private let shellPath: String?

    /// A live daemon session whose shell's current directory a fresh open
    /// starts in — the tab this one was opened from. Sent with the open
    /// only: an attach reaches a shell that already has a directory. The
    /// daemon reads the path from the kernel; the app never names one.
    private let inheritDirectoryFrom: UInt64?

    /// A directory a fresh open starts in when no live session can name it
    /// — a row of the recent list. Only ever a path the daemon itself
    /// reported (`TerminalDirectory.path`), handed straight back; the app
    /// composes no paths of its own. Sent with the open only, and ignored
    /// by the daemon when `inheritDirectoryFrom` names a live session.
    private let startDirectory: String?

    var onEvent: (@Sendable (TerminalTransportEvent) -> Void)? {
        get { lock.locked { _onEvent } }
        set { lock.locked { _onEvent = newValue } }
    }

    /// The session's process exited on its own, as opposed to the link
    /// dropping or the host detaching. Carries the dead session's id and the
    /// exit status.
    ///
    /// A `.disconnected` event alone cannot express this: a detach, a daemon
    /// crash, and `exit` typed into the shell all produce one, and a reason
    /// string is for humans, not for branching on. A host that persists
    /// session ids for reattachment should forget the id here — after this
    /// fires, reattaching to it can only fail. Delivered on the transport
    /// queue, immediately before the matching `.disconnected`.
    var onSessionExit: (@Sendable (UInt64, Int32) -> Void)? {
        get { lock.locked { _onSessionExit } }
        set { lock.locked { _onSessionExit = newValue } }
    }

    /// Shown to the user — a tab's title before the shell sets one, and the
    /// sidebar's subtitle — so it says "Session 7", not "ighostvtd session 7".
    /// The daemon-side id is what makes two untitled tabs tell apart.
    var endpointDescription: String {
        let hostName: String? = if case let .remote(hostID) = endpoint {
            PairedRemoteHostStore.host(id: hostID)?.displayName
        } else {
            nil
        }
        return lock.locked {
            guard let sessionID else {
                return hostName ?? String(localized: "Terminal")
            }
            if let hostName {
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Session %lld on %@",
                        comment: "Tab title for a remote shell that has not set one; %@ is the other device",
                    ),
                    Int(clamping: sessionID),
                    hostName,
                )
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("Session %lld", comment: "Tab title for a shell that has not set one"),
                Int(clamping: sessionID),
            )
        }
    }

    /// The daemon-side identifier, once open. Persist it to reattach later.
    var currentSessionID: UInt64? {
        lock.locked { sessionID }
    }

    init(
        endpoint: DaemonEndpoint = .local,
        shellPath: String? = nil,
        resumeSessionID: UInt64? = nil,
        inheritDirectoryFrom: UInt64? = nil,
        startDirectory: String? = nil,
    ) {
        self.endpoint = endpoint
        // The Settings shell is a path on this device; another device runs
        // its own default.
        let trimmed = endpoint.isRemote ? nil : shellPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shellPath = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.resumeSessionID = resumeSessionID
        self.inheritDirectoryFrom = inheritDirectoryFrom
        self.startDirectory = startDirectory
    }

    deinit {
        // An activated XPC connection must be canceled before its last
        // reference goes away. Normal teardown already did this; the deinit
        // covers an owner that dropped the transport without disconnecting.
        if let connection = lock.locked({ self.connection }) {
            connection.cancel()
        }
    }

    // Queued one-shot operations below capture `self` strongly on purpose.
    // The owner drops its reference immediately after asking for a close or
    // detach (`TerminalSessionStore.disconnect` nils the relay's transport),
    // and a `[weak self]` block then deallocates the transport before the
    // message is ever sent: the daemon keeps the shell attached forever, and
    // the still-activated XPC connection is released without a cancel. The
    // strong capture keeps the transport alive exactly until its queued work
    // — ending in `teardown`, which cancels the connection — has run.

    func connect(takingOver: Bool) {
        emit(.state(.connecting))
        queue.async {
            self.takesOver = takingOver
            self.establish()
        }
    }

    /// Keystrokes and pastes, in `inputChunkByteCount` messages.
    ///
    /// A paste is one call with the whole clipboard in it and can be any
    /// size, while a message may only carry `maximumMessageDataByteCount` —
    /// the daemon refuses more outright, which used to lose a large paste
    /// entirely. Chunks go out back to back on this one connection and are
    /// never waited on: XPC drains a connection's messages FIFO, so they
    /// reach the daemon in the order they are queued here, and the session
    /// feeds its PTY in that same order. Nothing needs an acknowledgement to
    /// stay in sequence, and asking for one would pace every paste at a
    /// round trip per chunk.
    ///
    /// Input larger than a keystroke carries a paste id on every chunk and
    /// asks for a reply it does not wait for. A program that is not reading
    /// fills the session's input backlog, and the daemon refuses from the
    /// first chunk that does not fit to the end of that paste — so what
    /// arrives is a prefix, never a paste with a hole in it — and the first
    /// refusal is reported once (`TerminalTransportEvent.inputRefused`).
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard let link = self.attachedLink() else { return }
            let paste = data.count > Self.pasteByteCount ? UInt64.random(in: 1 ... .max) : 0
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(
                    offset,
                    offsetBy: iGhostVTProtocol.inputChunkByteCount,
                    limitedBy: data.endIndex,
                ) ?? data.endIndex
                let message = Self.makeMessage(.write, sessionID: link.sessionID)
                data[offset ..< end].withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress {
                        xpc_dictionary_set_data(message, iGhostVTWireKey.data, base, buffer.count)
                    }
                }
                if paste == 0 {
                    link.connection.send(message)
                } else {
                    xpc_dictionary_set_uint64(message, iGhostVTWireKey.paste, paste)
                    link.connection.send(message) { [weak self] reply in
                        guard let self, Self.replyCode(of: reply) == .inputBacklog,
                              reportedRefusedPaste != paste else { return }
                        reportedRefusedPaste = paste
                        AppLog.warning(.transport, "session \(link.sessionID) refused the rest of a \(data.count) byte paste: its program is not reading")
                        emit(.inputRefused)
                    }
                }
                offset = end
            }
        }
    }

    /// More than the kernel takes into a terminal's input at once (about a
    /// kilobyte): input that may have to wait, which is what a refusal can
    /// cut short.
    private static let pasteByteCount = 1024
    /// Confined to `queue`: the paste whose refusal was last reported, so
    /// one paste is reported once however many of its chunks are refused.
    private var reportedRefusedPaste: UInt64 = 0

    /// Sizes the session, or records the size for the open to start at
    /// while there is none yet. The host calls this again on `.connected`,
    /// which is what carries a size reported during the open or attach
    /// round trip to the session: this transport never replays a size on
    /// its own, so a size captured before the trip can never outrank one
    /// reported during it.
    func updateViewport(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        queue.async {
            self.latestViewport = (columns, rows)
            guard let link = self.attachedLink() else { return }
            self.sendResize(columns: columns, rows: rows, over: link)
        }
    }

    /// Runs on `queue`.
    private func sendResize(
        columns: Int,
        rows: Int,
        over link: (connection: DaemonLink, sessionID: UInt64),
    ) {
        if let applied = appliedViewport, applied.columns == columns, applied.rows == rows {
            return
        }
        appliedViewport = (columns, rows)
        let message = Self.makeMessage(.resize, sessionID: link.sessionID)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, UInt64(columns))
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, UInt64(rows))
        link.connection.send(message)
    }

    /// One `setSessionAttributes` over the link, answered on `queue`. The
    /// app only ever sends the lock and the title, well inside the limits.
    func setSessionAttributes(_ attributes: [String: String]) {
        queue.async {
            guard let link = self.attachedLink() else {
                AppLog.warning(.transport, "session attributes not sent: no attached session")
                return
            }
            let message = Self.makeMessage(.setSessionAttributes, sessionID: link.sessionID)
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, value) in attributes {
                xpc_dictionary_set_string(dictionary, key, value)
            }
            xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, dictionary)
            link.connection.send(message) { reply in
                switch Self.replyCode(of: reply) {
                case .success:
                    break
                case let code:
                    AppLog.error(
                        .transport,
                        "session \(link.sessionID) attributes not stored: reply code \(code.rawValue)",
                    )
                }
            }
        }
    }

    /// Detach without killing: the shell keeps running in the daemon.
    func disconnect() {
        queue.async {
            if self.deferEnd(.detach) {
                return
            }
            if let link = self.attachedLink() {
                let message = Self.makeMessage(.detachSession, sessionID: link.sessionID)
                link.connection.send(message)
            }
            self.teardown(reason: nil)
        }
    }

    /// End the session for good — the daemon terminates the shell. Over
    /// the link when there is one; when the connection is gone but the
    /// session may not be (a failed connect, a daemon restart mid-reconnect),
    /// over a connection of its own, so the kill reaches the daemon either
    /// way. The decision is made here, on `queue`, behind the `establish`
    /// that a `connect()` queued just before — the caller cannot tell the
    /// two apart from outside.
    func closeSession() {
        queue.async {
            if self.deferEnd(.close) {
                return
            }
            let sessionID = self.lock.locked { () -> UInt64? in
                defer { self.resumeSessionID = nil }
                return self.resumeSessionID
            }
            if let link = self.attachedLink() {
                let message = Self.makeMessage(.closeSession, sessionID: link.sessionID)
                link.connection.send(message)
            } else if let sessionID {
                Self.killSession(sessionID, at: self.endpoint)
            }
        }
    }

    /// Runs on `queue`. Records `end` for the reply handler while the open
    /// or attach is still out, and says whether it did. The tab's close asks
    /// for a close and then a detach; the close stands.
    private func deferEnd(_ end: DeferredEnd) -> Bool {
        let isNegotiating = lock.locked { connection != nil && sessionID == nil }
        guard isNegotiating else { return false }
        if deferredEnd != .close {
            deferredEnd = end
        }
        retainedForDeferredEnd = self
        return true
    }

    /// Runs on `queue`, from the reply that ends the negotiation. Carries
    /// out the end asked for meanwhile — on `sessionID`, the session the
    /// reply named, or on nothing when it named none — and drops the
    /// connection. False when no end was deferred and the reply is to be
    /// used.
    private func settleDeferredEnd(sessionID: UInt64?) -> Bool {
        guard let end = deferredEnd else { return false }
        if let sessionID, let connection = lock.locked({ self.connection }) {
            let operation: iGhostVTOperation = end == .close ? .closeSession : .detachSession
            connection.send(Self.makeMessage(operation, sessionID: sessionID))
        }
        if end == .close {
            lock.locked { resumeSessionID = nil }
        }
        teardown(reason: nil)
        return true
    }

    /// One daemon-held session, as `listSessions` reports it. The daemon is
    /// the only book of record — the app deliberately persists nothing.
    struct SessionSummary: Equatable, Sendable {
        let id: UInt64
        let isAttached: Bool
        /// The device the session is held for, when it is held for one.
        var holder: String?
        /// What is in front of the shell now ("zsh", "vim").
        var processName: String?
        var directory: TerminalDirectory?
        /// The title the tab holding it shows, as that app stored it
        /// (`iGhostVTSessionAttribute.title`); nil from an app or daemon
        /// that keeps none.
        var title: String?
    }

    /// Ask the daemon what it is holding, over a one-shot connection of its
    /// own. Completion fires exactly once, on an arbitrary queue: rows on
    /// success, nil when the daemon is unreachable or does not answer within
    /// the timeout (a hung daemon must not hang cold launch with it).
    static func listSessions(
        timeout: TimeInterval = 6,
        completion: @escaping @Sendable ([SessionSummary]?) -> Void,
    ) {
        oneShotRequest(.listSessions, timeout: timeout, decode: sessions(in:), completion: completion)
    }

    /// Shell paths the daemon proved executable inside the active bootstrap.
    static func listShells(
        timeout: TimeInterval = 6,
        completion: @escaping @Sendable ([String]?) -> Void,
    ) {
        oneShotRequest(.listShells, timeout: timeout, decode: shells(in:), completion: completion)
    }

    /// `listSessions` on `endpoint` — another device's daemon, for the
    /// new-tab menu's list of its terminals. Nil when it does not answer.
    static func listSessions(
        at endpoint: DaemonEndpoint,
        timeout: TimeInterval = 6,
        completion: @escaping @Sendable ([SessionSummary]?) -> Void,
    ) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.list", qos: .userInitiated)
        let finished = FinishOnce<[SessionSummary]?>(completion)
        guard let connection = endpoint.makeLink(queue: queue) else {
            finished.finish(nil)
            return
        }
        connection.activate { event in
            if case .lost = event, finished.finish(nil) {
                connection.cancel()
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if finished.finish(nil) {
                connection.cancel()
            }
        }
        connection.send(makeMessage(.hello)) { reply in
            guard replyCode(of: reply) == .success else {
                if finished.finish(nil) {
                    connection.cancel()
                }
                return
            }
            connection.send(makeMessage(.listSessions)) { reply in
                connection.cancel()
                finished.finish(sessions(in: reply))
            }
        }
    }

    private static func oneShotRequest<Value: Sendable>(
        _ operation: iGhostVTOperation,
        timeout: TimeInterval,
        decode: @escaping @Sendable (xpc_object_t) -> Value?,
        completion: @escaping @Sendable (Value?) -> Void,
    ) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.list", qos: .userInitiated)
        let finished = FinishOnce<Value?>(completion)
        guard !AppEdition.isRemoteOnly,
              let rawConnection = iGhostVTProtocol.serviceName.withCString({
                  ighostvtCreateMachServiceConnection($0, queue, 0)
              })
        else {
            finished.finish(nil)
            return
        }
        // Boxed so the reply and timeout closures can carry it across the
        // Sendable boundary; all use stays on the one serial `queue`.
        let link = XPCConnectionBox(rawConnection)
        xpc_connection_set_event_handler(link.connection) { _ in }
        xpc_connection_activate(link.connection)
        queue.asyncAfter(deadline: .now() + timeout) {
            if finished.finish(nil) {
                xpc_connection_cancel(link.connection)
            }
        }
        xpc_connection_send_message_with_reply(link.connection, makeMessage(.hello), queue) { reply in
            guard Self.replyCode(of: reply) == .success else {
                if finished.finish(nil) {
                    xpc_connection_cancel(link.connection)
                }
                return
            }
            xpc_connection_send_message_with_reply(
                link.connection,
                makeMessage(operation),
                queue,
            ) { reply in
                xpc_connection_cancel(link.connection)
                finished.finish(decode(reply))
            }
        }
    }

    /// The rows of a `listSessions` reply; nil for anything but a success.
    private static func sessions(in reply: xpc_object_t) -> [SessionSummary]? {
        guard replyCode(of: reply) == .success,
              let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.sessions),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return nil }
        var rows: [SessionSummary] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let entry = xpc_array_get_value(array, index)
            guard xpc_get_type(entry) == iGhostVTXPC.typeDictionary else { continue }
            rows.append(SessionSummary(
                id: xpc_dictionary_get_uint64(entry, iGhostVTWireKey.sessionID),
                isAttached: xpc_dictionary_get_bool(entry, iGhostVTWireKey.isAttached),
                holder: string(iGhostVTWireKey.holder, in: entry),
                processName: string(iGhostVTWireKey.processName, in: entry),
                directory: string(iGhostVTWireKey.currentDirectory, in: entry).map {
                    TerminalDirectory(path: $0, display: string(iGhostVTWireKey.displayDirectory, in: entry))
                },
                title: xpc_dictionary_get_value(entry, iGhostVTWireKey.attributes)
                    .flatMap { string(iGhostVTSessionAttribute.title, in: $0) }
                    .flatMap { $0.isEmpty ? nil : $0 },
            ))
        }
        return rows
    }

    private static func shells(in reply: xpc_object_t) -> [String]? {
        guard replyCode(of: reply) == .success,
              let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.shells),
              xpc_get_type(array) == iGhostVTXPC.typeArray,
              xpc_array_get_count(array) <= iGhostVTProtocol.maximumListedShellCount
        else { return nil }
        var paths: [String] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let value = xpc_array_get_value(array, index)
            guard xpc_get_type(value) == iGhostVTXPC.typeString,
                  xpc_string_get_length(value) < MAXPATHLEN,
                  let pointer = xpc_string_get_string_ptr(value)
            else { return nil }
            let path = String(cString: pointer)
            guard path.hasPrefix("/") else { return nil }
            paths.append(path)
        }
        return paths
    }

    /// Kill a session over a connection of its own, for when there is no
    /// link to carry it — a tab that never connected, or a transport whose
    /// connection is gone (a failed connect, a detach, a daemon restart).
    /// Without this the kill silently goes nowhere, the shell outlives its
    /// tab forever, and each one counts against the daemon's session
    /// ceiling. `closeSession` is valid on any session the daemon knows,
    /// attached or not; an `unknownSession` reply means it is already gone.
    static func killSession(_ id: UInt64, at endpoint: DaemonEndpoint = .local) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.kill", qos: .utility)
        guard let connection = endpoint.makeLink(queue: queue) else { return }
        connection.activate { _ in }
        connection.send(makeMessage(.hello)) { _ in
            connection.send(Self.makeMessage(.closeSession, sessionID: id)) { _ in
                connection.cancel()
            }
        }
    }

    /// The quit path. Kills `ids` (every session the daemon holds, attached
    /// or not, when nil) and waits for the daemon to report each one *gone*
    /// — the close reply says only that the SIGHUP was sent, and a shell has
    /// up to the daemon's two-second grace to leave. A daemon left holding
    /// nothing exits by itself once this connection is gone.
    ///
    /// Blocking on purpose, bounded by `timeout` for the whole sequence:
    /// the one caller is `applicationWillTerminate`, where anything still
    /// queued dies with the process. The tabs' own transports cannot do
    /// this — `closeSession` there is fire-and-forget on a queue the exit
    /// would outrun, and the disconnect that follows drops the connection
    /// the exit event would have arrived on.
    static func closeSessionsForQuit(
        _ ids: [UInt64]?,
        timeout: TimeInterval = 3,
    ) {
        let deadline = DispatchTime.now() + timeout
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.quit", qos: .userInitiated)
        guard !AppEdition.isRemoteOnly,
              let connection = iGhostVTProtocol.serviceName.withCString({
                  ighostvtCreateMachServiceConnection($0, queue, 0)
              }) else { return }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        let done = DispatchGroup()
        done.enter()
        @Sendable func finish() {
            xpc_connection_cancel(connection)
            done.leave()
        }
        @Sendable func list(_ completion: @escaping @Sendable ([SessionSummary]?) -> Void) {
            xpc_connection_send_message_with_reply(connection, makeMessage(.listSessions), queue) { reply in
                completion(Self.sessions(in: reply))
            }
        }
        // Polls the daemon's list until none of `targets` remain, or the
        // deadline passes; hands over the last list either way.
        @Sendable func awaitGone(_ targets: Set<UInt64>, then: @escaping @Sendable ([SessionSummary]) -> Void) {
            list { rows in
                guard let rows else { return finish() }
                if !rows.contains(where: { targets.contains($0.id) }) || DispatchTime.now() >= deadline {
                    return then(rows)
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    awaitGone(targets, then: then)
                }
            }
        }
        xpc_connection_send_message_with_reply(connection, makeMessage(.hello), queue) { reply in
            guard Self.replyCode(of: reply) == .success else { return finish() }
            list { rows in
                guard let rows else { return finish() }
                // A terminal another device is using is that device's to
                // end, Keep Alive or not — even one a tab here still held a
                // moment ago, before the device took it.
                let held = Set(rows.filter { $0.holder == nil }.map(\.id))
                let targets = ids.map { held.intersection($0) } ?? held
                let kills = DispatchGroup()
                for id in targets {
                    kills.enter()
                    let message = Self.makeMessage(.closeSession, sessionID: id)
                    xpc_connection_send_message_with_reply(connection, message, queue) { _ in
                        kills.leave()
                    }
                }
                kills.notify(queue: queue) {
                    awaitGone(targets) { _ in
                        finish()
                    }
                }
            }
        }
        _ = done.wait(timeout: deadline)
    }

    // MARK: - Connection lifecycle

    private func establish() {
        guard let connection = endpoint.makeLink(queue: queue) else {
            emit(.state(.disconnected(
                reason: endpoint.isRemote
                    ? String(localized: "This device is no longer paired. Pair it again in Settings.")
                    : String(localized: "The terminal helper is not running. Restart iGhostVT and try again."),
            )))
            return
        }

        lock.locked { self.connection = connection }
        connection.activate { [weak self] event in
            self?.handle(event)
        }

        let hello = Self.makeMessage(.hello)
        isAwaitingHello = true
        connection.send(hello) { [weak self] reply in
            guard let self else { return }
            isAwaitingHello = false
            guard Self.replyCode(of: reply) == .success else {
                teardown(reason: connectFailureReason(reply))
                return
            }
            openOrAttachSession()
        }
        // A missing service answers the hello with an error at once. A
        // daemon launchd has registered but that never picks the message up
        // (hung, or crash-looping under KeepAlive) answers with nothing, and
        // the tab would say "Connecting…" for good with no way to retry.
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            guard let self, isAwaitingHello,
                  lock.locked({ self.connection === connection }) else { return }
            isAwaitingHello = false
            AppLog.error(.transport, "no hello reply after \(Int(Self.helloTimeout)) s")
            teardown(reason: connectFailureReason(nil))
        }
    }

    /// Why the hello failed, for the tab. A remote host says why itself
    /// when it can (an unpaired device, a helper that is not running).
    private func connectFailureReason(_ reply: xpc_object_t?) -> String {
        guard endpoint.isRemote else {
            return String(localized: "Unable to connect to the terminal helper. Restart iGhostVT and try again.")
        }
        if let reply, xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
           xpc_dictionary_get_int64(reply, iGhostVTWireKey.code) == iGhostVTReplyCode.unsupportedVersion.rawValue
        {
            let theirs = xpc_dictionary_get_string(reply, iGhostVTWireKey.appVersion).map { String(cString: $0) } ?? ""
            var name: String?
            if case let .remote(hostID) = endpoint {
                name = PairedRemoteHostStore.host(id: hostID)?.displayName
            }
            return RemoteVersionText.mismatch(theirs: theirs, name: name)
        }
        if let reply, xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
           let message = xpc_dictionary_get_string(reply, iGhostVTWireKey.errorMessage)
        {
            return String(cString: message)
        }
        return String(localized: "Unable to reach the other device. Check that remote access is on there, and that both devices are on the same network or use the same relay.")
    }

    /// Generous on purpose: the minute after a userspace reboot runs at a
    /// load of several hundred, and a slow hello is not a dead daemon.
    private static let helloTimeout: TimeInterval = 20
    /// Confined to `queue`.
    private var isAwaitingHello = false

    private var hasLoggedFirstOutput = false

    /// How often, and how far apart, an attach the daemon answers with
    /// `sessionBusy` is tried again before the tab gives up on the session:
    /// two seconds in all. A tab moved to another window attaches while the
    /// window it left is still detaching — that detach and this attach
    /// travel on two connections, and nothing orders one before the other.
    private static let busyAttachRetryLimit = 20
    private static let busyAttachRetryInterval: DispatchTimeInterval = .milliseconds(100)

    private func openOrAttachSession(busyRetries: Int = 0) {
        guard let connection = lock.locked({ self.connection }) else { return }
        if let resumeSessionID = lock.locked({ self.resumeSessionID }) {
            let message = Self.makeMessage(.attachSession)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, resumeSessionID)
            if takesOver {
                xpc_dictionary_set_bool(message, iGhostVTWireKey.takeover, true)
            }
            connection.send(message) { [weak self] reply in
                guard let self else { return }
                let code = Self.replyCode(of: reply)
                // A device has it: it stays there, and the tab says so —
                // no retry, since a device does not let go in two seconds.
                if code == .sessionBusy, let holder = Self.string(iGhostVTWireKey.holder, in: reply) {
                    if settleDeferredEnd(sessionID: nil) {
                        return
                    }
                    noteHeldElsewhere(holder: holder)
                    return
                }
                // Another device's terminal is never a window of this app
                // letting go: waiting cannot help.
                if code == .sessionBusy, endpoint.isRemote {
                    if settleDeferredEnd(sessionID: nil) {
                        return
                    }
                    noteHeldElsewhere(holder: nil)
                    return
                }
                if code == .sessionBusy, busyRetries < Self.busyAttachRetryLimit {
                    queue.asyncAfter(deadline: .now() + Self.busyAttachRetryInterval) { [weak self] in
                        guard let self, lock.locked({ self.connection === connection }) else { return }
                        openOrAttachSession(busyRetries: busyRetries + 1)
                    }
                    return
                }
                if code == .success {
                    if settleDeferredEnd(sessionID: resumeSessionID) {
                        return
                    }
                    lock.locked { self.sessionID = resumeSessionID }
                    // The attach carried no size; the reply says which one
                    // the session kept, so the host's re-send on
                    // `.connected` costs nothing when the grid is unchanged.
                    let columns = Int(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns))
                    let rows = Int(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows))
                    appliedViewport = columns > 0 && rows > 0 ? (columns, rows) : nil
                    emit(.state(.connected))
                    emit(.sessionResumed(true))
                    emitSessionState(in: reply)
                    emitSessionAttributes(in: reply, isResumed: true)
                    // Replayed scrollback so the surface rebuilds its screen.
                    // Repainted from a clean slate: on an in-app reconnect the
                    // surface still shows the session's last frame, and
                    // appending the whole replay below it reprints history the
                    // screen already has. Home + erase-display gives the
                    // replay the blank canvas a cold launch gets, and is a
                    // no-op on one.
                    if let replay = Self.data(iGhostVTWireKey.data, in: reply), !replay.isEmpty {
                        var payload = Data("\u{1B}[H\u{1B}[2J".utf8)
                        payload.append(replay)
                        emit(.received(payload, replay: true))
                    }
                } else if code == .sessionBusy {
                    // Another window of this app still has it after the
                    // retries: it is open there, not gone.
                    if settleDeferredEnd(sessionID: nil) {
                        return
                    }
                    noteHeldElsewhere(holder: nil)
                } else if endpoint.isRemote {
                    // A terminal on another device that is gone ended
                    // there; opening a fresh one would put a tab nobody
                    // asked for in the host's window. The tab closes.
                    if settleDeferredEnd(sessionID: nil) {
                        return
                    }
                    if code == .unknownSession {
                        lock.locked { self.resumeSessionID = nil }
                        onSessionExit?(resumeSessionID, 0)
                    }
                    teardown(reason: Self.failureReason(reply, code: code))
                } else {
                    // The session is gone: forget the id and open a fresh
                    // shell in this same tab. Not reported as an exit — the
                    // host closes a tab on one, which would discard the
                    // shell about to be opened; it learns the new id from
                    // `.connected` instead.
                    lock.locked { self.resumeSessionID = nil }
                    if settleDeferredEnd(sessionID: nil) {
                        return
                    }
                    openSession()
                }
            }
            return
        }
        openSession()
    }

    /// Runs on `queue`. Spawns at the grid reported so far — read here, not
    /// by the caller, since a failed attach reaches this after a round trip
    /// during which the surface may well have reported again.
    private func openSession() {
        guard let connection = lock.locked({ self.connection }) else { return }
        let columns = UInt64(latestViewport?.columns ?? Int(iGhostVTProtocol.defaultColumns))
        let rows = UInt64(latestViewport?.rows ?? Int(iGhostVTProtocol.defaultRows))
        let message = Self.makeMessage(.openSession)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, columns)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, rows)
        if let shellPath {
            // Just the path, under its own key: the daemon decides the argv
            // and the login environment that goes with it. A one-word `cmd`
            // would run the program as itself.
            xpc_dictionary_set_string(message, iGhostVTWireKey.shell, shellPath)
        }
        if let inheritDirectoryFrom {
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.inheritDirectoryFrom, inheritDirectoryFrom)
        }
        if let startDirectory {
            xpc_dictionary_set_string(message, iGhostVTWireKey.startDirectory, startDirectory)
        }
        connection.send(message) { [weak self] reply in
            guard let self else { return }
            let code = Self.replyCode(of: reply)
            guard code == .success else {
                teardown(reason: Self.failureReason(reply, code: code))
                return
            }
            let sessionID = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
            if settleDeferredEnd(sessionID: sessionID) {
                return
            }
            lock.locked {
                self.sessionID = sessionID
                self.resumeSessionID = sessionID
            }
            appliedViewport = (Int(columns), Int(rows))
            emit(.state(.connected))
            emit(.sessionResumed(false))
            emitSessionState(in: reply)
            emitSessionAttributes(in: reply, isResumed: false)
        }
    }

    private func handle(_ linkEvent: DaemonLinkEvent) {
        guard case let .message(event) = linkEvent else {
            // The link died out from under us — daemon restart, not a
            // session end. The resume ID survives, so a reconnect can
            // reattach to the still-running shell. A cancel this transport
            // performed itself also surfaces here as one last error event;
            // the connection is already forgotten then, and it must not be
            // reported as an interruption. Nor is a link that dies with an
            // end deferred on it: the host has already asked for the end,
            // and an interruption would have it reconnect a tab it closed.
            let wasEnding = deferredEnd != nil
            guard dropConnection() else { return }
            if wasEnding {
                emit(.state(.disconnected(reason: nil)))
                return
            }
            emit(.state(.interrupted(
                reason: String(localized: "The terminal connection was interrupted. Try again."),
            )))
            return
        }
        guard xpc_get_type(event) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_uint64(event, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let pushed = iGhostVTEvent(
                  rawValue: xpc_dictionary_get_uint64(event, iGhostVTWireKey.event),
              )
        else { return }

        let eventSessionID = xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID)
        guard eventSessionID == lock.locked({ sessionID }) else { return }

        switch pushed {
        case .output:
            if let data = Self.data(iGhostVTWireKey.data, in: event), !data.isEmpty {
                if !hasLoggedFirstOutput {
                    hasLoggedFirstOutput = true
                    AppLog.info(.transport, "first output event bytes=\(data.count) session=\(eventSessionID)")
                }
                emit(.received(data, replay: false))
            }
        case .processName:
            emitSessionState(in: event)
        case .sessionTaken:
            // Detached already; the resume id stays, to take it back with.
            noteHeldElsewhere(holder: Self.string(iGhostVTWireKey.holder, in: event))
        case .sessionOpened, .sessionReleased:
            // The watcher's (`HostSessionWatcher`); a tab's link gets none.
            break
        case .sessionExit:
            let exitCode = Int32(
                truncatingIfNeeded: xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode),
            )
            // The id is dead: clear it before anyone can try to resume it.
            lock.locked { resumeSessionID = nil }
            onSessionExit?(eventSessionID, exitCode)
            teardown(
                reason: exitCode == 0
                    ? String(localized: "The shell exited.")
                    : String.localizedStringWithFormat(
                        NSLocalizedString(
                            "The shell exited with status %lld.",
                            comment: "Why a terminal stopped; %lld is the process exit status",
                        ),
                        Int(exitCode),
                    ),
            )
        }
    }

    /// Runs on `queue`. The session is another peer's: the connection
    /// goes, the resume id stays. A device is named; with none named, the
    /// other side of a remote tab is the host itself.
    private func noteHeldElsewhere(holder: String?) {
        guard dropConnection() else { return }
        let hostName: String? = if case let .remote(hostID) = endpoint {
            PairedRemoteHostStore.host(id: hostID)?.displayName
        } else {
            nil
        }
        emit(.state(.heldElsewhere(holder: holder ?? hostName)))
    }

    private func teardown(reason: String?) {
        guard dropConnection() else { return }
        emit(.state(.disconnected(reason: reason)))
    }

    /// Cancels and forgets the connection, keeping the resume ID. Returns
    /// false when there was nothing to drop.
    @discardableResult
    private func dropConnection() -> Bool {
        let connection: DaemonLink? = lock.locked {
            let current = self.connection
            self.connection = nil
            self.sessionID = nil
            return current
        }
        // Still on `queue`: the connection targets it, so its error events
        // and every reply arrive there, and each other caller is a block on
        // it.
        appliedViewport = nil
        deferredEnd = nil
        retainedForDeferredEnd = nil
        guard let connection else { return false }
        connection.cancel()
        return true
    }

    /// The connection and its session id read together, so a teardown between
    /// two reads cannot pair a stale connection with a fresh id.
    private func attachedLink() -> (connection: DaemonLink, sessionID: UInt64)? {
        lock.locked {
            guard let connection = self.connection,
                  let sessionID = self.sessionID else { return nil }
            return (connection, sessionID)
        }
    }

    // MARK: - Wire helpers

    static func makeMessage(_ operation: iGhostVTOperation) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        return message
    }

    private static func makeMessage(_ operation: iGhostVTOperation, sessionID: UInt64) -> xpc_object_t {
        let message = makeMessage(operation)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
        return message
    }

    static func replyCode(of reply: xpc_object_t) -> iGhostVTReplyCode {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_uint64(reply, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let code = iGhostVTReplyCode(
                  rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code),
              )
        else { return .operationFailed }
        return code
    }

    private func emit(_ event: TerminalTransportEvent) {
        onEvent?(event)
    }

    /// What a reply or event 102 says the session is doing: the foreground
    /// process, and where its shell is. The directory is absent until the
    /// daemon has read one (and from a session whose shell cannot be
    /// read), which leaves the tab's where it was.
    private func emitSessionState(in dictionary: xpc_object_t) {
        if let name = Self.string(iGhostVTWireKey.processName, in: dictionary) {
            let isShell = xpc_dictionary_get_bool(dictionary, iGhostVTWireKey.foregroundIsShell)
            emit(.processName(name, isShell: isShell))
        }
        if let path = Self.string(iGhostVTWireKey.currentDirectory, in: dictionary) {
            emit(.currentDirectory(TerminalDirectory(
                path: path,
                display: Self.string(iGhostVTWireKey.displayDirectory, in: dictionary),
            )))
        }
    }

    /// What an open or attach reply says the daemon keeps on the session.
    /// Every reply on this protocol version carries the key; one without
    /// it is a fault, logged, and changes nothing the tab holds.
    private func emitSessionAttributes(in reply: xpc_object_t, isResumed: Bool) {
        guard let dictionary = xpc_dictionary_get_value(reply, iGhostVTWireKey.attributes),
              xpc_get_type(dictionary) == iGhostVTXPC.typeDictionary
        else {
            AppLog.error(.transport, "an open or attach reply carried no session attributes")
            return
        }
        var attributes: [String: String] = [:]
        xpc_dictionary_apply(dictionary) { key, value in
            if xpc_get_type(value) == iGhostVTXPC.typeString,
               let string = xpc_string_get_string_ptr(value)
            {
                attributes[String(cString: key)] = String(cString: string)
            }
            return true
        }
        emit(.sessionAttributes(attributes, isResumed: isResumed))
    }

    private static func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        guard xpc_get_type(dictionary) == iGhostVTXPC.typeDictionary,
              let value = xpc_dictionary_get_string(dictionary, key)
        else { return nil }
        return String(cString: value)
    }

    private static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        guard xpc_get_type(dictionary) == iGhostVTXPC.typeDictionary else { return nil }
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count),
              count <= iGhostVTProtocol.maximumMessageDataByteCount else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// The daemon's own sentence when it sent one — it knows which shell it
    /// tried and what the system said, and only the reply code survives
    /// otherwise. Falls back to the generic wording for a code with no detail.
    private static func failureReason(_ reply: xpc_object_t, code: iGhostVTReplyCode) -> String {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              let message = xpc_dictionary_get_string(reply, iGhostVTWireKey.errorMessage)
        else { return describe(code) }
        let text = String(cString: message)
        return text.isEmpty ? describe(code) : text
    }

    private static func describe(_ code: iGhostVTReplyCode) -> String {
        switch code {
        // Neither `.success` nor `.inputBacklog` reaches here: both callers
        // describe a failed open or attach, and a refused write is answered
        // on a path that asks for no reply at all. They take the generic
        // wording rather than inventing a sentence that would read as
        // nonsense in an error card.
        case .success, .operationFailed, .inputBacklog, .invalidRequest:
            String(localized: "Unable to complete this action. Try again.")
        case .unsupportedVersion:
            String(
                localized: "iGhostVT and its terminal helper are different versions. Reinstall iGhostVT to update both.",
            )
        case .handshakeRequired: String(localized: "The terminal connection is not ready. Try again.")
        case .sessionLimitReached: String(localized: "Too many terminals are open. Close one and try again.")
        case .unknownSession: String(localized: "This terminal is no longer available.")
        case .sessionBusy: String(localized: "This terminal is already open in another window.")
        case .spawnFailed: String(localized: "No usable shell was found. Check the default shell in Settings.")
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Carries an xpc_connection_t across Sendable closure boundaries. XPC
/// objects are thread-safe; the annotation is what the type system lacks.
private final class XPCConnectionBox: @unchecked Sendable {
    let connection: xpc_connection_t
    init(_ connection: xpc_connection_t) {
        self.connection = connection
    }
}

/// Guarantees a completion fires exactly once across the reply, error, and
/// timeout paths of a one-shot query. `finish` returns whether this call won.
private final class FinishOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Value) -> Void)?

    init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ value: Value) -> Bool {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return false }
        completion(value)
        return true
    }
}
