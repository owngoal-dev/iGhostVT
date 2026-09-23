import Darwin
import Dispatch
import Foundation
import os
import XPC

/// One client connection, as relayed by `ighostvtd`.
///
/// Requests arrive here as XPC dictionaries the proxy forwarded unchanged
/// and are answered on the control queue; output flows the other way as
/// unsolicited events stamped with this peer's id. A peer holds no session
/// state of its own — it attaches to sessions the registry owns. The
/// proxy's peer ids are unique per connection, so the handshake gate below
/// means what it did when this object *was* the connection.
final class PeerSession {
    let peerID: UInt64
    private let queue: DispatchQueue
    private let registry: SessionRegistry
    private unowned let host: IOHost

    private var didHandshake = false
    private var attachedSessionIDs: Set<UInt64> = []
    private var isValid = true

    init(peerID: UInt64, queue: DispatchQueue, registry: SessionRegistry, host: IOHost) {
        self.peerID = peerID
        self.queue = queue
        self.registry = registry
        self.host = host
    }

    // MARK: - Output toward the client

    func deliverOutput(sessionID: UInt64, data: Data) {
        guard isValid else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.event, iGhostVTEvent.output.rawValue)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, iGhostVTWireKey.data, base, buffer.count)
            }
        }
        host.send(.event, peer: peerID, tag: 0, message: message)
    }

    func deliverExit(sessionID: UInt64, exitCode: Int32) {
        guard isValid else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.event, iGhostVTEvent.sessionExit.rawValue)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
        xpc_dictionary_set_int64(message, iGhostVTWireKey.exitCode, Int64(exitCode))
        host.send(.event, peer: peerID, tag: 0, message: message)
        attachedSessionIDs.remove(sessionID)
    }

    /// Event 102: what the session's terminal is doing now. Sent whenever
    /// the session notices a change, and worded exactly as the open and
    /// attach replies word it.
    func deliverForeground(of session: PTYSession) {
        guard isValid else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.event, iGhostVTEvent.processName.rawValue)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, session.id)
        Self.setForegroundProcess(
            name: session.foregroundProcessName,
            isShell: session.isForegroundShell,
            in: message
        )
        Self.setDirectory(session.reportedDirectory, in: message)
        host.send(.event, peer: peerID, tag: 0, message: message)
    }

    /// The foreground process as every open/attach reply and event 102
    /// state it: the name, and whether it is the shell itself.
    private static func setForegroundProcess(name: String, isShell: Bool, in message: xpc_object_t) {
        xpc_dictionary_set_string(message, iGhostVTWireKey.processName, name)
        xpc_dictionary_set_bool(message, iGhostVTWireKey.foregroundIsShell, isShell)
    }

    /// A session's directory, in both spellings a client needs: the
    /// kernel's, which is what `startDirectory` wants handed back, and —
    /// where they differ — the one worth showing a person.
    private static func setDirectory(_ path: String?, in message: xpc_object_t) {
        guard let path else { return }
        xpc_dictionary_set_string(message, iGhostVTWireKey.currentDirectory, path)
        if let display = displaySpelling(of: path) {
            xpc_dictionary_set_string(message, iGhostVTWireKey.displayDirectory, display)
        }
    }

    /// How a directory should read to a person: the session user's home
    /// against `~`, anything else inside the bootstrap against `@jb`, and
    /// nothing at all for a path that is already its own best spelling —
    /// so the wire carries a second spelling only where it says something.
    ///
    /// The home is tested first because under roothide it is *inside* the
    /// bootstrap (`<jbroot>/var/mobile`), and `@jb/var/mobile` is a true
    /// but useless answer for the one directory every user recognises.
    /// Only the daemon can make this call at all: the app has no way to
    /// know where the session user's home is, and guessing `/var/mobile`
    /// names the wrong directory under roothide in both directions.
    private static func displaySpelling(of path: String) -> String? {
        if let home = ShellLaunch.sessionHomeDirectory,
           let spelled = RuntimeEnvironment.spelling(of: path, under: home, as: "~") {
            return spelled
        }
        return RuntimeEnvironment.displaySpelling(of: path)
    }

    // MARK: - Requests from the client

    /// `tag` is 0 when the client sent the message without expecting a
    /// reply; the proxy then has nothing to deliver one into.
    func handle(_ message: xpc_object_t, tag: UInt64) {
        guard isValid else { return }
        let reply: xpc_object_t? = tag != 0 ? xpc_dictionary_create(nil, nil, 0) : nil
        let outcome = process(message, reply: reply)
        if let reply {
            xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, outcome.code.rawValue)
            host.send(.reply, peer: peerID, tag: tag, message: reply)
        }
        switch outcome.then {
        case .nothing:
            break
        case .closePeer:
            host.removePeer(peerID)
        case .exitProcess:
            host.exitAfterShutdown()
        }
    }

    private struct Outcome {
        enum Follow {
            case nothing
            case closePeer
            case exitProcess
        }

        let code: iGhostVTReplyCode
        let then: Follow

        init(_ code: iGhostVTReplyCode, then: Follow = .nothing) {
            self.code = code
            self.then = then
        }
    }

    private func process(_ message: xpc_object_t, reply: xpc_object_t?) -> Outcome {
        guard xpc_dictionary_get_uint64(message, iGhostVTWireKey.version) == iGhostVTProtocol.version else {
            return Outcome(.unsupportedVersion)
        }
        guard let operation = iGhostVTOperation(
            rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation)
        ) else {
            return Outcome(.invalidRequest)
        }
        guard didHandshake || operation == .hello else {
            return Outcome(.handshakeRequired)
        }

        switch operation {
        case .hello:
            didHandshake = true
            return Outcome(.success)
        case .listSessions:
            return Outcome(listSessions(into: reply))
        case .listShells:
            return Outcome(listShells(into: reply))
        case .openSession:
            return Outcome(openSession(message, reply: reply))
        case .attachSession:
            return Outcome(attachSession(message, reply: reply))
        case .detachSession:
            return Outcome(detachSession(message))
        case .write:
            return Outcome(write(message))
        case .resize:
            return Outcome(resize(message))
        case .closeSession:
            return Outcome(closeSession(message))
        case .snapshotSession:
            return Outcome(snapshotSession(message, reply: reply))
        case .injectInput:
            return Outcome(injectInput(message))
        case .goodbye:
            return Outcome(.success, then: .closePeer)
        case .shutdown:
            // Only with nothing held: a session the app did not close is a
            // shell someone is coming back for. Replied to before exiting,
            // so the quitting app hears the outcome.
            guard registry.isEmpty else { return Outcome(.sessionBusy) }
            DaemonFileLog.log("peer \(peerID) shutdown with nothing held")
            return Outcome(.success, then: .exitProcess)
        }
    }

    private func listSessions(into reply: xpc_object_t?) -> iGhostVTReplyCode {
        guard let reply else { return .success }
        let summaries = registry.summaries
        let array = xpc_array_create(nil, 0)
        for summary in summaries {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(entry, iGhostVTWireKey.sessionID, summary.id)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.title, summary.title)
            xpc_dictionary_set_uint64(entry, iGhostVTWireKey.columns, UInt64(summary.columns))
            xpc_dictionary_set_uint64(entry, iGhostVTWireKey.rows, UInt64(summary.rows))
            xpc_dictionary_set_bool(entry, iGhostVTWireKey.isAttached, summary.isAttached)
            Self.setForegroundProcess(
                name: summary.processName,
                isShell: summary.isForegroundShell,
                in: entry
            )
            Self.setDirectory(summary.currentDirectory, in: entry)
            xpc_array_append_value(array, entry)
        }
        xpc_dictionary_set_value(reply, iGhostVTWireKey.sessions, array)
        return .success
    }

    private func listShells(into reply: xpc_object_t?) -> iGhostVTReplyCode {
        guard let reply else { return .success }
        let array = xpc_array_create(nil, 0)
        for path in ShellLaunch.availableShellPaths {
            xpc_array_append_value(array, xpc_string_create(path))
        }
        xpc_dictionary_set_value(reply, iGhostVTWireKey.shells, array)
        return .success
    }

    private func openSession(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhostVTReplyCode {
        guard attachedSessionIDs.count < iGhostVTProtocol.maximumSessionsPerPeer else {
            return .sessionLimitReached
        }
        let command = stringArray(message, key: iGhostVTWireKey.command)
        let shell = xpc_dictionary_get_string(message, iGhostVTWireKey.shell).map { String(cString: $0) }
        let environment = stringDictionary(message, key: iGhostVTWireKey.environment)
        let columns = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, iGhostVTWireKey.columns))
        let rows = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, iGhostVTWireKey.rows))
        let inheritDirectoryFrom = optionalUInt64(message, key: iGhostVTWireKey.inheritDirectoryFrom)
        let startDirectory = xpc_dictionary_get_string(message, iGhostVTWireKey.startDirectory)
            .map { String(cString: $0) }

        DaemonFileLog.log("peer \(peerID) openSession \(columns)x\(rows)")
        do {
            let session = try registry.open(
                command: command,
                shell: shell,
                environment: environment,
                columns: columns,
                rows: rows,
                inheritDirectoryFrom: inheritDirectoryFrom,
                startDirectory: startDirectory
            )
            _ = try registry.attach(session.id, to: self)
            attachedSessionIDs.insert(session.id)
            if let reply {
                xpc_dictionary_set_uint64(reply, iGhostVTWireKey.sessionID, session.id)
                Self.setForegroundProcess(
                    name: session.foregroundProcessName,
                    isShell: session.isForegroundShell,
                    in: reply
                )
                Self.setDirectory(session.currentDirectory, in: reply)
            }
            return .success
        } catch let failure as iGhostVTFailure {
            // The app shows this verbatim, so a session that never started can
            // say which shell it tried and what the system answered.
            DaemonLog.sessions.error(
                "open for peer \(self.peerID) failed: \(failure.message, privacy: .public)"
            )
            DaemonFileLog.log("open for peer \(peerID) failed: \(failure.message)")
            if let reply {
                xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, failure.message)
            }
            return failure.code
        } catch let code as iGhostVTReplyCode {
            DaemonLog.sessions.error(
                "open for peer \(self.peerID) failed: reply code \(code.rawValue)"
            )
            return code
        } catch {
            return .spawnFailed
        }
    }

    private func attachSession(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        do {
            let session = try registry.attach(id, to: self)
            attachedSessionIDs.insert(id)
            if let reply {
                Self.describe(session, into: reply)
            }
            DaemonLog.sessions.info("peer \(self.peerID) attached session \(id)")
            DaemonFileLog.log("peer \(peerID) attached session \(id)")
            return .success
        } catch let code as iGhostVTReplyCode {
            DaemonLog.sessions.error(
                "attach session \(id) for peer \(self.peerID) failed: reply code \(code.rawValue)"
            )
            DaemonFileLog.log("attach session \(id) for peer \(peerID) failed: reply code \(code.rawValue)")
            return code
        } catch {
            return .operationFailed
        }
    }

    private func detachSession(_ message: xpc_object_t) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        registry.detach(id, from: self)
        attachedSessionIDs.remove(id)
        DaemonLog.sessions.info("peer \(self.peerID) detached session \(id)")
        return .success
    }

    private func write(_ message: xpc_object_t) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        guard attachedSessionIDs.contains(id), let session = registry.session(id) else {
            return .unknownSession
        }
        guard let input = Self.inputData(in: message) else { return .invalidRequest }
        guard session.write(input) else {
            DaemonFileLog.log(
                "peer \(peerID) write of \(input.count) byte(s) refused: session \(id) holds \(session.pendingInputByteCount) byte(s) its program has not read"
            )
            return .inputBacklog
        }
        return .success
    }

    /// `write` for a peer that holds nothing: the CLI's `send`. Not gated
    /// on attachment, like `closeSession` and for the same reason — every
    /// peer here passed audit-token authentication and can list every
    /// session. The peer attached to it sees the echo like any other
    /// keystroke; this peer receives nothing.
    private func injectInput(_ message: xpc_object_t) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        guard let session = registry.session(id) else { return .unknownSession }
        guard let input = Self.inputData(in: message) else { return .invalidRequest }
        DaemonFileLog.log("peer \(peerID) injectInput \(input.count) byte(s) into session \(id)")
        guard session.write(input) else { return .inputBacklog }
        return .success
    }

    /// An attach reply without the attach: the CLI's `capture`. Whoever
    /// holds the session keeps holding it.
    private func snapshotSession(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        guard let session = registry.session(id) else { return .unknownSession }
        if let reply {
            Self.describe(session, into: reply)
        }
        return .success
    }

    /// The size, the foreground process, the directory, and the replay
    /// buffer — what an attach and a snapshot both answer with.
    private static func describe(_ session: PTYSession, into reply: xpc_object_t) {
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.columns, UInt64(session.columns))
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.rows, UInt64(session.rows))
        setForegroundProcess(
            name: session.foregroundProcessName,
            isShell: session.isForegroundShell,
            in: reply
        )
        // Read live rather than from the last poll: an attach is rare, and
        // the tab it answers wants the directory the shell is in now.
        setDirectory(session.currentDirectory, in: reply)
        let replay = session.replayData()
        replay.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress, !replay.isEmpty {
                xpc_dictionary_set_data(reply, iGhostVTWireKey.data, base, buffer.count)
            }
        }
    }

    /// The `data` a `write` or `injectInput` carries, `nil` when absent or
    /// over the per-message cap.
    private static func inputData(in message: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(message, iGhostVTWireKey.data, &count),
              count <= iGhostVTProtocol.maximumMessageDataByteCount
        else {
            return nil
        }
        return Data(bytes: bytes, count: count)
    }

    private func resize(_ message: xpc_object_t) -> iGhostVTReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        guard attachedSessionIDs.contains(id), let session = registry.session(id) else {
            return .unknownSession
        }
        let columns = xpc_dictionary_get_uint64(message, iGhostVTWireKey.columns)
        let rows = xpc_dictionary_get_uint64(message, iGhostVTWireKey.rows)
        guard columns > 0, columns <= UInt64(iGhostVTProtocol.maximumColumns),
              rows > 0, rows <= UInt64(iGhostVTProtocol.maximumRows)
        else {
            return .invalidRequest
        }
        session.resize(columns: UInt16(columns), rows: UInt16(rows))
        return .success
    }

    private func closeSession(_ message: xpc_object_t) -> iGhostVTReplyCode {
        // Deliberately not gated on being attached. A tab whose connection
        // dropped still has to be closable, and requiring an attach first
        // meant the app silently skipped the kill for exactly those tabs —
        // the shell then lived on with nothing left to reach it. Every peer
        // here already passed audit-token authentication and can see every
        // session through `listSessions`, so closing one it did not open is
        // no more privilege than it already had.
        let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        DaemonFileLog.log("peer \(peerID) closeSession \(id)")
        do {
            try registry.close(id)
            attachedSessionIDs.remove(id)
            return .success
        } catch let code as iGhostVTReplyCode {
            return code
        } catch {
            return .operationFailed
        }
    }

    /// The connection behind this peer is gone. Sessions survive: the
    /// client going away is a detach, not a kill.
    func invalidate() {
        guard isValid else { return }
        isValid = false
        registry.detachAll(for: self)
        attachedSessionIDs.removeAll()
    }

    // MARK: - Wire helpers

    /// Absent and zero are different things for a session id, so this
    /// distinguishes them where `xpc_dictionary_get_uint64` would not.
    private func optionalUInt64(_ message: xpc_object_t, key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(message, key),
              xpc_get_type(value) == iGhostVTXPC.typeUInt64 else { return nil }
        return xpc_uint64_get_value(value)
    }

    private func stringArray(_ message: xpc_object_t, key: String) -> [String] {
        guard let array = xpc_dictionary_get_value(message, key),
              xpc_get_type(array) == iGhostVTXPC.typeArray else { return [] }
        // Read every element: the length limit is `ShellLaunch.validate`'s to
        // refuse. Trimming here would run a different command than was asked.
        var values: [String] = []
        for index in 0 ..< xpc_array_get_count(array) {
            guard let value = xpc_array_get_string(array, index) else { continue }
            values.append(String(cString: value))
        }
        return values
    }

    private func stringDictionary(_ message: xpc_object_t, key: String) -> [String: String] {
        guard let dictionary = xpc_dictionary_get_value(message, key),
              xpc_get_type(dictionary) == iGhostVTXPC.typeDictionary else { return [:] }
        var values: [String: String] = [:]
        xpc_dictionary_apply(dictionary) { entryKey, entryValue in
            if xpc_get_type(entryValue) == iGhostVTXPC.typeString,
               let string = xpc_string_get_string_ptr(entryValue)
            {
                values[String(cString: entryKey)] = String(cString: string)
            }
            return true
        }
        return values
    }
}
