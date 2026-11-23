import Foundation
@preconcurrency import XPC

/// The MCP server as `mcpStatus` reports it.
struct MCPServerStatus: Equatable, Sendable {
    var isEnabled = false
    var state: MCPServerState = .off
    /// Clients holding a token, as the server last said.
    var authorizedClients = 0
    /// The daemon could not be asked at all.
    var isUnavailable = false
}

/// A client waiting for the person's answer (`mcpConsentRequests`).
struct MCPConsentRequest: Identifiable, Equatable, Sendable {
    var id: UInt64
    var clientName: String
    var redirect: String
    var code: String
    var expiresAt: Date

    /// The code as the consent page shows it, in two groups of three.
    var spacedCode: String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

/// The MCP operations the app sends this device's daemon, each over a
/// one-shot connection. The proxy answers them itself and lets only the app
/// switch the server, open the consent window and answer a request
/// (`MCPSupervisor`).
enum MCPServerControl {
    static func status() async -> MCPServerStatus {
        parseStatus(await request(.mcpStatus))
    }

    static func setEnabled(_ enabled: Bool) async -> MCPServerStatus {
        parseStatus(await request(.setMCPServer) { xpc_dictionary_set_bool($0, iGhostVTWireKey.enabled, enabled) })
    }

    static func forgetClients() async -> MCPServerStatus {
        parseStatus(await request(.forgetMCPClients))
    }

    /// Opened while the page is up, renewed before it lapses, closed as the
    /// page goes; closing refuses whatever is still waiting.
    @discardableResult
    static func setConsentWindow(open: Bool) async -> Bool {
        let reply = await request(.setMCPConsentWindow) { xpc_dictionary_set_bool($0, iGhostVTWireKey.open, open) }
        return reply.map(isSuccess) ?? false
    }

    static func waitingRequests() async -> [MCPConsentRequest] {
        guard let reply = await request(.mcpConsentRequests), isSuccess(reply),
              let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.requests),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return [] }
        return (0 ..< xpc_array_get_count(array)).compactMap { index in
            let entry = xpc_array_get_value(array, index)
            guard xpc_get_type(entry) == iGhostVTXPC.typeDictionary,
                  let code = string(iGhostVTWireKey.consentCode, in: entry)
            else { return nil }
            return MCPConsentRequest(
                id: xpc_dictionary_get_uint64(entry, iGhostVTWireKey.requestID),
                clientName: string(iGhostVTWireKey.clientName, in: entry) ?? "",
                redirect: string(iGhostVTWireKey.redirect, in: entry) ?? "",
                code: code,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(xpc_dictionary_get_int64(entry, iGhostVTWireKey.expiresAt))),
            )
        }
    }

    @discardableResult
    static func answer(_ requestID: UInt64, allow: Bool) async -> Bool {
        let reply = await request(.answerMCPConsent) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.requestID, requestID)
            xpc_dictionary_set_bool(message, iGhostVTWireKey.allow, allow)
        }
        return reply.map(isSuccess) ?? false
    }

    // MARK: - The wire

    private static func request(
        _ operation: iGhostVTOperation,
        _ fill: (xpc_object_t) -> Void = { _ in },
    ) async -> xpc_object_t? {
        guard !AppEdition.isRemoteOnly else { return nil }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        fill(message)
        let box = MCPReplyBox(message)
        let reply: MCPReplyBox? = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.mcp")
            let finished = MCPReplyOnce(continuation)
            guard let link = XPCDaemonLink(queue: queue) else {
                finished.resume(nil)
                return
            }
            link.activate { event in
                if case .lost = event {
                    finished.resume(nil)
                }
            }
            queue.asyncAfter(deadline: .now() + 6) {
                finished.resume(nil)
                link.cancel()
            }
            let hello = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(hello, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_uint64(hello, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
            link.send(hello) { _ in
                link.send(box.message) { reply in
                    finished.resume(MCPReplyBox(reply))
                    link.cancel()
                }
            }
        }
        guard let reply, xpc_get_type(reply.message) == iGhostVTXPC.typeDictionary else { return nil }
        return reply.message
    }

    private static func parseStatus(_ reply: xpc_object_t?) -> MCPServerStatus {
        guard let reply, isSuccess(reply) else { return MCPServerStatus(isUnavailable: true) }
        return MCPServerStatus(
            isEnabled: xpc_dictionary_get_bool(reply, iGhostVTWireKey.enabled),
            state: string(iGhostVTWireKey.mcpState, in: reply).flatMap(MCPServerState.init(rawValue:)) ?? .off,
            authorizedClients: Int(clamping: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.mcpClients)),
        )
    }

    private static func isSuccess(_ reply: xpc_object_t) -> Bool {
        xpc_dictionary_get_int64(reply, iGhostVTWireKey.code) == iGhostVTReplyCode.success.rawValue
    }

    private static func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }
}

private struct MCPReplyBox: @unchecked Sendable {
    let message: xpc_object_t
    init(_ message: xpc_object_t) {
        self.message = message
    }
}

/// Resumes a continuation once, whichever of reply, loss or timeout comes
/// first.
private final class MCPReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MCPReplyBox?, Never>?

    init(_ continuation: CheckedContinuation<MCPReplyBox?, Never>) {
        self.continuation = continuation
    }

    func resume(_ reply: MCPReplyBox?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: reply)
    }
}
