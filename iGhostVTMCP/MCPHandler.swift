import Foundation

/// Minimalist MCP Streamable HTTP JSON-RPC 2.0 handler.
final class MCPHandler {
    private static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let defaultProtocolVersion = "2025-03-26"

    private let backend: ShellBackend
    private let allowAllSessions: Bool
    private let serverVersion: String
    private let lock = NSLock()
    private var activeSessions: Set<String> = []

    init(backend: ShellBackend, allowAllSessions: Bool, serverVersion: String = "1.0.0") {
        self.backend = backend
        self.allowAllSessions = allowAllSessions
        self.serverVersion = serverVersion
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case "POST":
            return handlePost(request)
        case "DELETE":
            if let sid = request.header("mcp-session-id") {
                lock.lock()
                activeSessions.remove(sid)
                lock.unlock()
            }
            return HTTPResponse(status: 204)
        case "GET":
            return HTTPResponse.text("SSE stream not offered; use POST /mcp", status: 405, extraHeaders: [("Allow", "POST, DELETE")])
        default:
            return HTTPResponse.text("Method not allowed", status: 405, extraHeaders: [("Allow", "POST, DELETE")])
        }
    }

    private func handlePost(_ request: HTTPRequest) -> HTTPResponse {
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return rpcError(id: NSNull(), code: -32700, message: "Parse error")
        }

        let id = payload["id"]
        guard let method = payload["method"] as? String else {
            return rpcError(id: id ?? NSNull(), code: -32600, message: "Invalid Request: missing method")
        }
        let params = payload["params"] as? [String: Any] ?? [:]

        // Notifications carry no `id` and expect 202 Accepted with no body.
        if id == nil {
            return HTTPResponse(status: 202)
        }
        let requestID = id!

        switch method {
        case "initialize":
            let requestedVersion = params["protocolVersion"] as? String
            let negotiated = (requestedVersion != nil && Self.supportedProtocolVersions.contains(requestedVersion!))
                ? requestedVersion!
                : Self.defaultProtocolVersion
            let sessionID = OAuthStore.randomURLSafeToken(byteCount: 16)
            lock.lock()
            activeSessions.insert(sessionID)
            lock.unlock()
            return rpcResult(
                id: requestID,
                result: [
                    "protocolVersion": negotiated,
                    "capabilities": [
                        "tools": [:],
                    ],
                    "serverInfo": [
                        "name": "ighostvt-mcp",
                        "version": serverVersion,
                    ],
                ],
                extraHeaders: [("Mcp-Session-Id", sessionID)],
            )

        case "ping":
            return rpcResult(id: requestID, result: [:])

        case "tools/list":
            return rpcResult(id: requestID, result: ["tools": Self.toolDefinitions])

        case "tools/call":
            return handleToolCall(id: requestID, params: params)

        default:
            return rpcError(id: requestID, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any, params: [String: Any]) -> HTTPResponse {
        guard let name = params["name"] as? String else {
            return rpcError(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text: String
            switch name {
            case "shell_exec":
                guard let command = args["command"] as? String, !command.isEmpty else {
                    throw MCPBackendError.invalidArgument("command is required")
                }
                let result = try backend.execCommand(
                    command: command,
                    cwd: args["cwd"] as? String,
                    shell: args["shell"] as? String,
                    env: args["env"] as? [String: String],
                    timeoutMs: Self.intValue(args["timeout_ms"]) ?? 30_000,
                    maxOutputBytes: Self.intValue(args["max_output_bytes"]) ?? 65_536,
                )
                let obj: [String: Any] = [
                    "output": result.output,
                    "exit_code": result.exitCode as Any,
                    "timed_out": result.timedOut,
                ]
                text = Self.prettyJSON(obj)

            case "session_list":
                let sessions = try backend.listSessions(allowAll: allowAllSessions)
                let rows: [[String: Any]] = sessions.map { s in
                    [
                        "session_id": s.id,
                        "title": s.title,
                        "process": s.processName ?? "",
                        "cwd": s.currentDirectory ?? "",
                        "columns": s.columns,
                        "rows": s.rows,
                        "attached": s.isAttached,
                        "mcp_owned": s.isMCPOwned,
                    ]
                }
                text = Self.prettyJSON(["sessions": rows])

            case "session_open":
                let sid = try backend.openSession(
                    cwd: args["cwd"] as? String,
                    shell: args["shell"] as? String,
                    command: args["command"] as? [String],
                    env: args["env"] as? [String: String],
                    columns: Self.uint16Value(args["columns"]),
                    rows: Self.uint16Value(args["rows"]),
                    showInApp: (args["show_in_app"] as? Bool) ?? false,
                )
                text = Self.prettyJSON(["session_id": sid])

            case "session_send":
                guard let sid = Self.uint64Value(args["session_id"]) else {
                    throw MCPBackendError.invalidArgument("session_id is required")
                }
                try backend.sendInput(
                    sessionID: sid,
                    text: args["text"] as? String,
                    keys: args["keys"] as? [String],
                    allowAll: allowAllSessions,
                )
                text = Self.prettyJSON(["ok": true, "session_id": sid])

            case "session_read":
                guard let sid = Self.uint64Value(args["session_id"]) else {
                    throw MCPBackendError.invalidArgument("session_id is required")
                }
                let full = (args["full"] as? Bool) ?? false
                text = try backend.readSession(sessionID: sid, full: full, allowAll: allowAllSessions)

            case "session_close":
                guard let sid = Self.uint64Value(args["session_id"]) else {
                    throw MCPBackendError.invalidArgument("session_id is required")
                }
                try backend.closeSession(sessionID: sid, allowAll: allowAllSessions)
                text = Self.prettyJSON(["closed": true, "session_id": sid])

            default:
                return rpcError(id: id, code: -32602, message: "Unknown tool: \(name)")
            }

            return rpcResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch {
            return rpcResult(id: id, result: [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true,
            ])
        }
    }

    // MARK: - JSON-RPC Helpers

    private func rpcResult(id: Any, result: Any, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse.json(["jsonrpc": "2.0", "id": id, "result": result], status: 200, extraHeaders: extraHeaders)
    }

    private func rpcError(id: Any, code: Int, message: String) -> HTTPResponse {
        HTTPResponse.json([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ], status: 200)
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private static func uint16Value(_ raw: Any?) -> UInt16? {
        guard let n = intValue(raw), n > 0, n <= Int(UInt16.max) else { return nil }
        return UInt16(n)
    }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        if let n = raw as? UInt64 { return n }
        if let n = raw as? Int, n >= 0 { return UInt64(n) }
        if let n = raw as? NSNumber, n.int64Value >= 0 { return n.uint64Value }
        if let s = raw as? String { return UInt64(s) }
        return nil
    }

    // MARK: - Tool Schemas

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "shell_exec",
            "description": "Execute a shell command in a temporary iGhostVT PTY session and return its rendered output and exit code.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Shell command to run."],
                    "cwd": ["type": "string", "description": "Optional working directory path."],
                    "shell": ["type": "string", "description": "Optional shell binary path (default: /bin/sh)."],
                    "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Optional environment variables."],
                    "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default: 30000, max: 300000)."],
                    "max_output_bytes": ["type": "integer", "description": "Maximum UTF-8 bytes returned (default: 65536)."],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "session_list",
            "description": "List accessible iGhostVT terminal sessions.",
            "inputSchema": [
                "type": "object",
                "properties": [:],
            ],
        ],
        [
            "name": "session_open",
            "description": "Open a persistent interactive iGhostVT terminal session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "cwd": ["type": "string", "description": "Starting working directory."],
                    "shell": ["type": "string", "description": "Shell executable path."],
                    "command": ["type": "array", "items": ["type": "string"], "description": "Optional command and arguments to run instead of the default shell."],
                    "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Optional environment variables."],
                    "columns": ["type": "integer", "description": "Terminal width in columns."],
                    "rows": ["type": "integer", "description": "Terminal height in rows."],
                    "show_in_app": ["type": "boolean", "description": "Bring the new session forward in iGhostVT."],
                ],
            ],
        ],
        [
            "name": "session_send",
            "description": "Send literal text and/or tmux-style key names (Enter, C-c, Tab, Up, etc.) to a terminal session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "integer", "description": "Target session ID."],
                    "text": ["type": "string", "description": "Literal text to type."],
                    "keys": ["type": "array", "items": ["type": "string"], "description": "Key names such as Enter, C-c, Escape, Tab."],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "session_read",
            "description": "Read the rendered screen (or full scrollback transcript) of a terminal session without stealing app focus.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "integer", "description": "Target session ID."],
                    "full": ["type": "boolean", "description": "Return full retained transcript instead of only the visible screen."],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "session_close",
            "description": "Close an iGhostVT terminal session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "integer", "description": "Target session ID."],
                ],
                "required": ["session_id"],
            ],
        ],
    ]
}
