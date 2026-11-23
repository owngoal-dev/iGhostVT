import Darwin
import Dispatch
import Foundation
import notify
import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtMCPCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

struct MCPSessionInfo {
    var id: UInt64
    var title: String
    var columns: UInt16
    var rows: UInt16
    var isAttached: Bool
    var processName: String?
    var currentDirectory: String?
    var isMCPOwned: Bool
}

struct MCPExecResult {
    var output: String
    var exitCode: Int?
    var timedOut: Bool
}

enum MCPBackendError: LocalizedError {
    case daemonUnreachable
    case timedOut
    case refused(String)
    case sessionNotAccessible(UInt64)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable:
            "Unable to reach ighostvtd. Open iGhostVT and try again."
        case .timedOut:
            "Timed out waiting for ighostvtd."
        case let .refused(message):
            message
        case let .sessionNotAccessible(id):
            "Session \(id) does not exist or is not owned by MCP (start with --allow-all-sessions to access user sessions)."
        case let .invalidArgument(message):
            message
        }
    }
}

protocol ShellBackend: AnyObject {
    func listSessions(allowAll: Bool) throws -> [MCPSessionInfo]
    func openSession(
        cwd: String?,
        shell: String?,
        command: [String]?,
        env: [String: String]?,
        columns: UInt16?,
        rows: UInt16?,
        showInApp: Bool,
    ) throws -> UInt64
    func sendInput(sessionID: UInt64, text: String?, keys: [String]?, allowAll: Bool) throws
    func readSession(sessionID: UInt64, full: Bool, allowAll: Bool) throws -> String
    func closeSession(sessionID: UInt64, allowAll: Bool) throws
    func execCommand(
        command: String,
        cwd: String?,
        shell: String?,
        env: [String: String]?,
        timeoutMs: Int,
        maxOutputBytes: Int,
    ) throws -> MCPExecResult
}

/// XPC client talking to `ighostvtd` on macOS and jailbroken iOS.
/// Uses `iGhostVTXPC` exclusively so the binary stays compatible with iOS 15.
final class DaemonShellBackend: ShellBackend {
    static let mcpAttributeKey = "mcp"
    static let mcpAttributeValue = "1"
    private static let requestTimeout: TimeInterval = 6

    private func withConnection<T>(_ body: (xpc_connection_t, DispatchQueue) throws -> T) throws -> T {
        #if os(macOS)
            guard getuid() != 0 else {
                throw MCPBackendError.refused("ighostvtd runs per-user on macOS, not as root.")
            }
        #endif
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.mcp.xpc")
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtMCPCreateMachServiceConnection($0, queue, 0)
        }) else {
            throw MCPBackendError.daemonUnreachable
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }

        _ = try send(.hello, on: connection, queue: queue) { _ in }
        return try body(connection, queue)
    }

    private func send(
        _ operation: iGhostVTOperation,
        on connection: xpc_connection_t,
        queue: DispatchQueue,
        fill: (xpc_object_t) -> Void,
    ) throws -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        fill(message)

        let done = DispatchSemaphore(value: 0)
        var received: xpc_object_t?
        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            received = reply
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            throw MCPBackendError.timedOut
        }
        guard let reply = received, xpc_get_type(reply) == iGhostVTXPC.typeDictionary else {
            throw MCPBackendError.daemonUnreachable
        }
        let codeRaw = xpc_dictionary_get_int64(reply, iGhostVTWireKey.code)
        let code = iGhostVTReplyCode(rawValue: codeRaw) ?? .operationFailed
        guard code == .success else {
            let detail = Self.string(reply, iGhostVTWireKey.errorMessage)
            throw MCPBackendError.refused(detail ?? "Daemon refused operation (code \(codeRaw))")
        }
        return reply
    }

    func listSessions(allowAll: Bool) throws -> [MCPSessionInfo] {
        try withConnection { connection, queue in
            let all = try fetchSessions(on: connection, queue: queue)
            return allowAll ? all : all.filter(\.isMCPOwned)
        }
    }

    func openSession(
        cwd: String?,
        shell: String?,
        command: [String]?,
        env: [String: String]?,
        columns: UInt16?,
        rows: UInt16?,
        showInApp: Bool,
    ) throws -> UInt64 {
        let resolvedCWD = try cwd.map(Self.canonicalDirectory)
        return try withConnection { connection, queue in
            let sessionID = try openSessionInternal(
                cwd: resolvedCWD,
                shell: shell,
                command: command,
                env: env,
                columns: columns ?? iGhostVTProtocol.defaultColumns,
                rows: rows ?? iGhostVTProtocol.defaultRows,
                on: connection,
                queue: queue,
            )
            if showInApp {
                Self.notifyAppToShow(sessionID: sessionID)
            }
            return sessionID
        }
    }

    func sendInput(sessionID: UInt64, text: String?, keys: [String]?, allowAll: Bool) throws {
        var bytes: [UInt8] = []
        if let text, !text.isEmpty {
            bytes.append(contentsOf: text.utf8)
        }
        if let keys {
            for key in keys {
                guard let encoded = KeyNames.bytes(for: key) else {
                    throw MCPBackendError.invalidArgument("Unknown key name '\(key)'. Supported: \(KeyNames.vocabulary)")
                }
                bytes.append(contentsOf: encoded)
            }
        }
        guard !bytes.isEmpty else { return }

        try withConnection { connection, queue in
            try ensureAccessible(sessionID: sessionID, allowAll: allowAll, on: connection, queue: queue)
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + iGhostVTProtocol.inputChunkByteCount)
                let chunk = Array(bytes[offset ..< end])
                _ = try send(.injectInput, on: connection, queue: queue) { msg in
                    xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
                    chunk.withUnsafeBytes {
                        xpc_dictionary_set_data(msg, iGhostVTWireKey.data, $0.baseAddress!, $0.count)
                    }
                }
                offset = end
            }
        }
    }

    func readSession(sessionID: UInt64, full: Bool, allowAll: Bool) throws -> String {
        try withConnection { connection, queue in
            try ensureAccessible(sessionID: sessionID, allowAll: allowAll, on: connection, queue: queue)
            return try snapshotText(sessionID: sessionID, full: full, on: connection, queue: queue)
        }
    }

    func closeSession(sessionID: UInt64, allowAll: Bool) throws {
        try withConnection { connection, queue in
            try ensureAccessible(sessionID: sessionID, allowAll: allowAll, on: connection, queue: queue)
            _ = try send(.closeSession, on: connection, queue: queue) { msg in
                xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
            }
        }
    }

    func execCommand(
        command: String,
        cwd: String?,
        shell: String?,
        env: [String: String]?,
        timeoutMs: Int,
        maxOutputBytes: Int,
    ) throws -> MCPExecResult {
        let resolvedCWD = try cwd.map(Self.canonicalDirectory)
        let boundedTimeout = max(500, min(timeoutMs, 300_000))
        let boundedOutput = max(1024, min(maxOutputBytes, 256 * 1024))

        let marker = "__IGHOSTVT_MCP_EXIT_\(OAuthStore.randomURLSafeToken(byteCount: 12))__"
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/sh"
        let script = """
        \(command)
        __igvt_ec=$?
        printf '\\n\(marker):%d\\n' "$__igvt_ec"
        exit "$__igvt_ec"
        """

        return try withConnection { connection, queue in
            let sessionID = try openSessionInternal(
                cwd: resolvedCWD,
                shell: nil,
                command: [shellPath, "-c", script],
                env: env,
                columns: 160,
                rows: 48,
                on: connection,
                queue: queue,
            )
            defer {
                _ = try? send(.closeSession, on: connection, queue: queue) { msg in
                    xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
                }
            }

            let deadline = Date().addingTimeInterval(TimeInterval(boundedTimeout) / 1000.0)
            var lastTranscript = ""
            var sleepNs: UInt64 = 50_000_000 // 50ms

            while Date() < deadline {
                if let text = try? snapshotText(sessionID: sessionID, full: true, on: connection, queue: queue) {
                    lastTranscript = text
                    if let parsed = Self.extractMarker(from: text, marker: marker) {
                        return MCPExecResult(
                            output: Self.truncateUTF8(parsed.output, maxBytes: boundedOutput),
                            exitCode: parsed.exitCode,
                            timedOut: false,
                        )
                    }
                } else {
                    // Session exited before we saw the marker; return whatever we captured.
                    return MCPExecResult(
                        output: Self.truncateUTF8(lastTranscript, maxBytes: boundedOutput),
                        exitCode: nil,
                        timedOut: false,
                    )
                }
                var ts = timespec(tv_sec: 0, tv_nsec: Int(sleepNs))
                nanosleep(&ts, nil)
                sleepNs = min(sleepNs + 25_000_000, 200_000_000)
            }

            if let text = try? snapshotText(sessionID: sessionID, full: true, on: connection, queue: queue) {
                lastTranscript = text
            }
            return MCPExecResult(
                output: Self.truncateUTF8(lastTranscript, maxBytes: boundedOutput),
                exitCode: nil,
                timedOut: true,
            )
        }
    }

    // MARK: - Internal XPC Helpers

    private func openSessionInternal(
        cwd: String?,
        shell: String?,
        command: [String]?,
        env: [String: String]?,
        columns: UInt16,
        rows: UInt16,
        on connection: xpc_connection_t,
        queue: DispatchQueue,
    ) throws -> UInt64 {
        let reply = try send(.openSession, on: connection, queue: queue) { msg in
            xpc_dictionary_set_uint64(msg, iGhostVTWireKey.columns, UInt64(columns))
            xpc_dictionary_set_uint64(msg, iGhostVTWireKey.rows, UInt64(rows))
            if let cwd {
                xpc_dictionary_set_string(msg, iGhostVTWireKey.startDirectory, cwd)
            }
            if let shell, !shell.isEmpty {
                xpc_dictionary_set_string(msg, iGhostVTWireKey.shell, shell)
            }
            if let env, !env.isEmpty {
                let dict = xpc_dictionary_create(nil, nil, 0)
                for (k, v) in env {
                    xpc_dictionary_set_string(dict, k, v)
                }
                xpc_dictionary_set_value(msg, iGhostVTWireKey.environment, dict)
            }
            if let command, !command.isEmpty {
                let arr = xpc_array_create(nil, 0)
                for arg in command {
                    xpc_array_append_value(arr, xpc_string_create(arg))
                }
                xpc_dictionary_set_value(msg, iGhostVTWireKey.command, arr)
            }
        }

        let sessionID = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
        _ = try? send(.setSessionAttributes, on: connection, queue: queue) { msg in
            xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
            let attrs = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(attrs, Self.mcpAttributeKey, Self.mcpAttributeValue)
            xpc_dictionary_set_value(msg, iGhostVTWireKey.attributes, attrs)
        }
        _ = try? send(.detachSession, on: connection, queue: queue) { msg in
            xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
        }
        return sessionID
    }

    private func fetchSessions(on connection: xpc_connection_t, queue: DispatchQueue) throws -> [MCPSessionInfo] {
        let reply = try send(.listSessions, on: connection, queue: queue) { _ in }
        guard let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.sessions),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else {
            return []
        }

        var result: [MCPSessionInfo] = []
        let count = xpc_array_get_count(array)
        for idx in 0 ..< count {
            let item = xpc_array_get_value(array, idx)
            guard xpc_get_type(item) == iGhostVTXPC.typeDictionary else { continue }
            var isMCP = false
            if let attrs = xpc_dictionary_get_value(item, iGhostVTWireKey.attributes),
               xpc_get_type(attrs) == iGhostVTXPC.typeDictionary,
               Self.string(attrs, Self.mcpAttributeKey) == Self.mcpAttributeValue
            {
                isMCP = true
            }
            result.append(MCPSessionInfo(
                id: xpc_dictionary_get_uint64(item, iGhostVTWireKey.sessionID),
                title: Self.string(item, iGhostVTWireKey.title) ?? "",
                columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(item, iGhostVTWireKey.columns)),
                rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(item, iGhostVTWireKey.rows)),
                isAttached: xpc_dictionary_get_bool(item, iGhostVTWireKey.isAttached),
                processName: Self.string(item, iGhostVTWireKey.processName),
                currentDirectory: Self.string(item, iGhostVTWireKey.displayDirectory)
                    ?? Self.string(item, iGhostVTWireKey.currentDirectory),
                isMCPOwned: isMCP,
            ))
        }
        return result
    }

    private func ensureAccessible(
        sessionID: UInt64,
        allowAll: Bool,
        on connection: xpc_connection_t,
        queue: DispatchQueue,
    ) throws {
        let sessions = try fetchSessions(on: connection, queue: queue)
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw MCPBackendError.sessionNotAccessible(sessionID)
        }
        if !allowAll, !session.isMCPOwned {
            throw MCPBackendError.sessionNotAccessible(sessionID)
        }
    }

    private func snapshotText(
        sessionID: UInt64,
        full: Bool,
        on connection: xpc_connection_t,
        queue: DispatchQueue,
    ) throws -> String {
        let reply = try send(.snapshotSession, on: connection, queue: queue) { msg in
            xpc_dictionary_set_uint64(msg, iGhostVTWireKey.sessionID, sessionID)
        }
        let cols = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns))
        let rows = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows))
        let renderer = ScreenRenderer(
            columns: cols == 0 ? iGhostVTProtocol.defaultColumns : cols,
            rows: rows == 0 ? iGhostVTProtocol.defaultRows : rows,
        )
        if let replay = Self.data(reply, iGhostVTWireKey.data) {
            renderer.feed(replay)
        }
        return full ? renderer.transcriptText() : renderer.screenText()
    }

    private static func notifyAppToShow(sessionID: UInt64) {
        var token: Int32 = 0
        if notify_register_check(iGhostVTProtocol.showSessionNotification, &token) == NOTIFY_STATUS_OK {
            _ = notify_set_state(token, sessionID)
            _ = notify_post(iGhostVTProtocol.showSessionNotification)
            _ = notify_cancel(token)
        }
    }

    static func extractMarker(from text: String, marker: String) -> (output: String, exitCode: Int)? {
        let prefix = "\(marker):"
        guard let range = text.range(of: prefix, options: .backwards) else { return nil }
        let after = text[range.upperBound...]
        let digits = after.prefix { $0.isNumber || $0 == "-" }
        guard let exitCode = Int(digits) else { return nil }
        var output = String(text[..<range.lowerBound])
        while output.hasSuffix("\n") || output.hasSuffix("\r") {
            output.removeLast()
        }
        return (output, exitCode)
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        let tail = data.suffix(maxBytes)
        let decoded = String(decoding: tail, as: UTF8.self)
        return "... [truncated to last \(maxBytes) bytes]\n" + decoded
    }

    private static func canonicalDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw MCPBackendError.invalidArgument("No directory at \(path)")
        }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MCPBackendError.invalidArgument("Not a directory: \(path)")
        }
        return String(cString: resolved)
    }

    private static func string(_ dict: xpc_object_t, _ key: String) -> String? {
        withExtendedLifetime(dict) {
            xpc_dictionary_get_string(dict, key).map { String(cString: $0) }
        }
    }

    private static func data(_ dict: xpc_object_t, _ key: String) -> Data? {
        withExtendedLifetime(dict) {
            var length = 0
            guard let ptr = xpc_dictionary_get_data(dict, key, &length), length > 0 else { return nil }
            return Data(bytes: ptr, count: length)
        }
    }
}
