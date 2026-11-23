import CryptoKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

final class MockBackend: ShellBackend {
    var sessions: [UInt64: (info: MCPSessionInfo, buffer: String)] = [
        1: (
            MCPSessionInfo(
                id: 1,
                title: "user-tab",
                columns: 80,
                rows: 24,
                isAttached: true,
                processName: "zsh",
                currentDirectory: "/Users/test",
                isMCPOwned: false,
            ),
            "private user screen",
        ),
    ]
    var nextID: UInt64 = 10

    func listSessions(allowAll: Bool) throws -> [MCPSessionInfo] {
        let all = sessions.values.map(\.info).sorted { $0.id < $1.id }
        return allowAll ? all : all.filter(\.isMCPOwned)
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
        let id = nextID
        nextID += 1
        sessions[id] = (
            MCPSessionInfo(
                id: id,
                title: shell ?? "zsh",
                columns: columns ?? 80,
                rows: rows ?? 24,
                isAttached: showInApp,
                processName: command?.first ?? "zsh",
                currentDirectory: cwd ?? "/tmp",
                isMCPOwned: true,
            ),
            "ready> ",
        )
        return id
    }

    func sendInput(sessionID: UInt64, text: String?, keys: [String]?, allowAll: Bool) throws {
        guard var entry = sessions[sessionID], allowAll || entry.info.isMCPOwned else {
            throw MCPBackendError.sessionNotAccessible(sessionID)
        }
        if let text { entry.buffer += text }
        if let keys { entry.buffer += "[\(keys.joined(separator: ","))]" }
        sessions[sessionID] = entry
    }

    func readSession(sessionID: UInt64, full: Bool, allowAll: Bool) throws -> String {
        guard let entry = sessions[sessionID], allowAll || entry.info.isMCPOwned else {
            throw MCPBackendError.sessionNotAccessible(sessionID)
        }
        return full ? "FULL:\(entry.buffer)" : entry.buffer
    }

    func closeSession(sessionID: UInt64, allowAll: Bool) throws {
        guard let entry = sessions[sessionID], allowAll || entry.info.isMCPOwned else {
            throw MCPBackendError.sessionNotAccessible(sessionID)
        }
        sessions.removeValue(forKey: sessionID)
    }

    func execCommand(
        command: String,
        cwd: String?,
        shell: String?,
        env: [String: String]?,
        timeoutMs: Int,
        maxOutputBytes: Int,
    ) throws -> MCPExecResult {
        MCPExecResult(output: "ran:\(command)", exitCode: 0, timedOut: false)
    }
}

private func base64URLSHA256(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return Data(digest)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func jsonBody(_ response: HTTPResponse) -> [String: Any] {
    guard let obj = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
        fputs("FAIL: expected JSON body, got: \(String(decoding: response.body, as: UTF8.self))\n", stderr)
        exit(1)
    }
    return obj
}

private func makeRequest(
    _ method: String,
    _ path: String,
    query: [String: String] = [:],
    headers: [String: String] = [:],
    body: Data = Data(),
) -> HTTPRequest {
    var lower: [String: String] = [:]
    for (k, v) in headers { lower[k.lowercased()] = v }
    return HTTPRequest(method: method, path: path, query: query, headers: lower, body: body)
}

private func makeJSONRequest(
    _ method: String,
    _ path: String,
    headers: [String: String] = [:],
    json: Any,
) -> HTTPRequest {
    let data = try! JSONSerialization.data(withJSONObject: json)
    var h = headers
    h["Content-Type"] = "application/json"
    return makeRequest(method, path, headers: h, body: data)
}

private func makeFormRequest(
    _ method: String,
    _ path: String,
    form: [String: String],
) -> HTTPRequest {
    let encoded = form.map { k, v in
        let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
        let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
        return "\(ek)=\(ev)"
    }.joined(separator: "&")
    return makeRequest(method, path, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(encoded.utf8))
}

private func extractHiddenNonce(from html: String) -> String? {
    let marker = "name=\"nonce\" value=\""
    guard let start = html.range(of: marker)?.upperBound else { return nil }
    guard let end = html[start...].firstIndex(of: "\"") else { return nil }
    return String(html[start ..< end])
}

// MARK: - Run Tests

let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ighostvt-mcp-test-\(getpid())")
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

let stateFile = tempDir.appendingPathComponent("oauth.json")
let issuer = "http://127.0.0.1:18765"
let oauth = OAuthStore(issuer: issuer, stateURL: stateFile)
let backend = MockBackend()
let mcp = MCPHandler(backend: backend, allowAllSessions: false)
let router = MCPRouter(oauth: oauth, mcp: mcp)

// 1. Discovery metadata
let prm = router.handle(makeRequest("GET", "/.well-known/oauth-protected-resource"))
expect(prm.status == 200, "protected resource metadata should return 200")
expect((jsonBody(prm)["resource"] as? String) == "\(issuer)/mcp", "resource mismatch")

let asm = router.handle(makeRequest("GET", "/.well-known/oauth-authorization-server"))
expect(asm.status == 200, "auth server metadata should return 200")
expect((jsonBody(asm)["registration_endpoint"] as? String) == "\(issuer)/register", "registration_endpoint mismatch")

// 2. Origin CSRF guard
let badOrigin = router.handle(makeRequest("GET", "/health", headers: ["Origin": "https://evil.example"]))
expect(badOrigin.status == 403, "cross-origin request must be 403")

// 3. Unauthenticated /mcp returns 401 with resource_metadata
let unauth = router.handle(makeJSONRequest("POST", "/mcp", json: ["jsonrpc": "2.0", "id": 1, "method": "ping"]))
expect(unauth.status == 401, "unauthenticated /mcp must return 401")
let wwwAuth = unauth.headers.first { $0.0.lowercased() == "www-authenticate" }?.1 ?? ""
expect(wwwAuth.contains("resource_metadata="), "401 must include WWW-Authenticate resource_metadata")

// 4. Dynamic Client Registration validation
let badReg = router.handle(makeJSONRequest("POST", "/register", json: [
    "client_name": "Evil",
    "redirect_uris": ["http://evil.example/cb"],
]))
expect(badReg.status == 400, "non-loopback http redirect_uri must be rejected")

let redirectURI = "http://127.0.0.1:54321/callback"
let reg = router.handle(makeJSONRequest("POST", "/register", json: [
    "client_name": "Claude Code",
    "redirect_uris": [redirectURI],
]))
expect(reg.status == 201, "valid DCR must return 201")
let clientID = jsonBody(reg)["client_id"] as! String

// 5. OAuth 2.1 Authorization Code + PKCE S256
let verifier = "test-pkce-verifier-0123456789abcdef"
let challenge = base64URLSHA256(verifier)

let authGet = router.handle(makeRequest("GET", "/authorize", query: [
    "response_type": "code",
    "client_id": clientID,
    "redirect_uri": redirectURI,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
    "state": "xyz123",
]))
expect(authGet.status == 200, "GET /authorize should return HTML consent page")
let html = String(decoding: authGet.body, as: UTF8.self)
let nonce = extractHiddenNonce(from: html)!
expect(!nonce.isEmpty, "consent HTML must include hidden nonce")

let authPost = router.handle(makeFormRequest("POST", "/authorize", form: [
    "nonce": nonce,
    "decision": "approve",
]))
expect(authPost.status == 302, "POST /authorize approve must redirect")
let location = authPost.headers.first { $0.0.lowercased() == "location" }!.1
let callbackComponents = URLComponents(string: location)!
let code = callbackComponents.queryItems!.first { $0.name == "code" }!.value!
let returnedState = callbackComponents.queryItems!.first { $0.name == "state" }!.value!
expect(returnedState == "xyz123", "state must round-trip")

// Wrong PKCE verifier must fail & consume code
let badTok = router.handle(makeFormRequest("POST", "/token", form: [
    "grant_type": "authorization_code",
    "code": code,
    "client_id": clientID,
    "redirect_uri": redirectURI,
    "code_verifier": "wrong-verifier",
]))
expect(badTok.status == 400, "wrong PKCE verifier must fail")

// Re-authorize and succeed
let authGet2 = router.handle(makeRequest("GET", "/authorize", query: [
    "response_type": "code",
    "client_id": clientID,
    "redirect_uri": redirectURI,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
]))
let nonce2 = extractHiddenNonce(from: String(decoding: authGet2.body, as: UTF8.self))!
let authPost2 = router.handle(makeFormRequest("POST", "/authorize", form: ["nonce": nonce2, "decision": "approve"]))
let code2 = URLComponents(string: authPost2.headers.first { $0.0.lowercased() == "location" }!.1)!
    .queryItems!.first { $0.name == "code" }!.value!

let tok = router.handle(makeFormRequest("POST", "/token", form: [
    "grant_type": "authorization_code",
    "code": code2,
    "client_id": clientID,
    "redirect_uri": redirectURI,
    "code_verifier": verifier,
]))
expect(tok.status == 200, "valid PKCE exchange must succeed")
let tokJSON = jsonBody(tok)
let accessToken = tokJSON["access_token"] as! String
let refreshToken = tokJSON["refresh_token"] as! String

// Refresh token rotation
let refreshed = router.handle(makeFormRequest("POST", "/token", form: [
    "grant_type": "refresh_token",
    "refresh_token": refreshToken,
    "client_id": clientID,
]))
expect(refreshed.status == 200, "refresh_token grant must succeed")
let newAccessToken = jsonBody(refreshed)["access_token"] as! String
expect(newAccessToken != accessToken, "refresh must rotate access_token")

// 6. Authenticated MCP calls + session isolation
let authHeader = ["Authorization": "Bearer \(newAccessToken)"]

let initResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": ["protocolVersion": "2025-03-26"],
]))
expect(initResp.status == 200, "initialize must succeed")
expect(initResp.headers.contains { $0.0.lowercased() == "mcp-session-id" }, "initialize must return Mcp-Session-Id")

let listToolsResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
]))
let tools = (jsonBody(listToolsResp)["result"] as! [String: Any])["tools"] as! [[String: Any]]
expect(tools.count == 6, "expected 6 MCP tools, got \(tools.count)")

// Private user session 1 must NOT be readable when allowAllSessions == false
let readPrivate = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": ["name": "session_read", "arguments": ["session_id": 1]],
]))
let readPrivateResult = jsonBody(readPrivate)["result"] as! [String: Any]
expect((readPrivateResult["isError"] as? Bool) == true, "non-MCP session must be denied by default")

// Open MCP session, send input, read, close
let openResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": ["name": "session_open", "arguments": ["cwd": "/tmp"]],
]))
let openResult = jsonBody(openResp)["result"] as! [String: Any]
expect((openResult["isError"] as? Bool) == false, "session_open should succeed")

let sendResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": ["name": "session_send", "arguments": ["session_id": 10, "text": "ls", "keys": ["Enter"]]],
]))
expect(((jsonBody(sendResp)["result"] as! [String: Any])["isError"] as? Bool) == false, "session_send should succeed")

let readResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 6,
    "method": "tools/call",
    "params": ["name": "session_read", "arguments": ["session_id": 10]],
]))
let readContent = ((jsonBody(readResp)["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String
expect(readContent.contains("ls[Enter]"), "session_read should contain sent input")

let execResp = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 7,
    "method": "tools/call",
    "params": ["name": "shell_exec", "arguments": ["command": "echo hi"]],
]))
let execText = ((jsonBody(execResp)["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String
expect(execText.contains("ran:echo hi"), "shell_exec should return output")

// Revoke token and verify 401
let revokeResp = router.handle(makeFormRequest("POST", "/revoke", form: ["token": newAccessToken]))
expect(revokeResp.status == 200, "revoke should return 200")
let afterRevoke = router.handle(makeJSONRequest("POST", "/mcp", headers: authHeader, json: [
    "jsonrpc": "2.0",
    "id": 8,
    "method": "ping",
]))
expect(afterRevoke.status == 401, "revoked token must return 401")

// 7. Marker parsing check
let parsed = DaemonShellBackend.extractMarker(from: "hello world\n__MARKER__:42\n", marker: "__MARKER__")
expect(parsed?.output == "hello world" && parsed?.exitCode == 42, "marker extraction failed")

// 8. End-to-end TCP loopback smoke test via LocalHTTPServer
let liveServer = LocalHTTPServer(host: "127.0.0.1", port: 0) { req in
    router.handle(req)
}
try! liveServer.start()
defer { liveServer.stop() }
expect(liveServer.boundPort > 0, "LocalHTTPServer must bind an ephemeral port")

let healthURL = URL(string: "http://127.0.0.1:\(liveServer.boundPort)/health")!
let sem = DispatchSemaphore(value: 0)
var healthOK = false
URLSession.shared.dataTask(with: healthURL) { data, resp, _ in
    if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data,
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       (obj["ok"] as? Bool) == true
    {
        healthOK = true
    }
    sem.signal()
}.resume()
expect(sem.wait(timeout: .now() + 5) == .success && healthOK, "live TCP /health check failed")

print("MCPHarness: all tests passed")
