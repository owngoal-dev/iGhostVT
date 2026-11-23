import CryptoKit
import Darwin
import Foundation
import Security

/// Minimalist OAuth 2.1 authorization server for MCP (RFC 9728, RFC 8414,
/// RFC 7591 Dynamic Client Registration, Authorization Code + PKCE S256,
/// and Refresh Tokens).
final class OAuthStore {
    struct ClientRecord: Codable {
        var clientID: String
        var clientName: String
        var redirectURIs: [String]
        var createdAt: TimeInterval
    }

    struct TokenRecord: Codable {
        var accessToken: String
        var refreshToken: String
        var clientID: String
        var scope: String
        var expiresAt: TimeInterval
        var refreshExpiresAt: TimeInterval
    }

    private struct PendingConsent {
        var nonce: String
        var clientID: String
        var clientName: String
        var redirectURI: String
        var state: String?
        var codeChallenge: String
        var scope: String
        var expiresAt: TimeInterval
    }

    private struct AuthCode {
        var code: String
        var clientID: String
        var redirectURI: String
        var codeChallenge: String
        var scope: String
        var expiresAt: TimeInterval
    }

    private struct PersistedState: Codable {
        var clients: [String: ClientRecord]
        var tokens: [TokenRecord]
    }

    static let accessTokenTTL: TimeInterval = 24 * 60 * 60
    static let refreshTokenTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let consentTTL: TimeInterval = 5 * 60
    private static let authCodeTTL: TimeInterval = 60

    let issuer: String
    private let stateURL: URL?
    private let staticToken: String?

    private let lock = NSLock()
    private var clients: [String: ClientRecord] = [:]
    private var tokens: [TokenRecord] = []
    private var pendingConsents: [String: PendingConsent] = [:]
    private var authCodes: [String: AuthCode] = [:]

    init(issuer: String, stateURL: URL?, staticToken: String? = nil) {
        self.issuer = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        self.stateURL = stateURL
        self.staticToken = staticToken?.isEmpty == false ? staticToken : nil
        loadState()
    }

    static var defaultStateURL: URL {
        #if os(macOS)
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/iGhostVT", isDirectory: true)
        #else
            let base = URL(fileURLWithPath: "/var/mobile/Library/Application Support/iGhostVT", isDirectory: true)
        #endif
        return base.appendingPathComponent("mcp-oauth.json")
    }

    static func revokeAll(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Bearer Verification

    func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.header("authorization") else { return false }
        let prefix = "bearer "
        guard header.lowercased().hasPrefix(prefix) else { return false }
        let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return false }

        if let staticToken, Self.constantTimeEqual(token, staticToken) {
            return true
        }

        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        return tokens.contains { record in
            record.expiresAt > now && Self.constantTimeEqual(record.accessToken, token)
        }
    }

    func unauthorizedResponse() -> HTTPResponse {
        let metadataURL = "\(issuer)/.well-known/oauth-protected-resource"
        return HTTPResponse.json(
            ["error": "invalid_token", "error_description": "Authorization required"],
            status: 401,
            extraHeaders: [
                ("WWW-Authenticate", "Bearer realm=\"ighostvt-mcp\", resource_metadata=\"\(metadataURL)\""),
            ],
        )
    }

    // MARK: - Discovery Metadata

    func protectedResourceMetadata() -> HTTPResponse {
        HTTPResponse.json([
            "resource": "\(issuer)/mcp",
            "authorization_servers": [issuer],
            "bearer_methods_supported": ["header"],
            "scopes_supported": ["shell"],
        ])
    }

    func authorizationServerMetadata() -> HTTPResponse {
        HTTPResponse.json([
            "issuer": issuer,
            "authorization_endpoint": "\(issuer)/authorize",
            "token_endpoint": "\(issuer)/token",
            "registration_endpoint": "\(issuer)/register",
            "revocation_endpoint": "\(issuer)/revoke",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["shell"],
        ])
    }

    // MARK: - RFC 7591 Dynamic Client Registration

    func handleRegister(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse.text("Method not allowed", status: 405, extraHeaders: [("Allow", "POST")])
        }
        guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return oauthError("invalid_client_metadata", "Expected JSON object")
        }
        guard let redirectURIs = json["redirect_uris"] as? [String], !redirectURIs.isEmpty else {
            return oauthError("invalid_redirect_uri", "redirect_uris must be a non-empty array")
        }
        for uri in redirectURIs {
            guard Self.isAllowedRedirectURI(uri) else {
                return oauthError("invalid_redirect_uri", "Disallowed redirect_uri: \(uri)")
            }
        }

        let clientName = (json["client_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (clientName?.isEmpty == false) ? clientName! : "MCP Client"
        let clientID = "mcp_" + Self.randomURLSafeToken(byteCount: 16)
        let now = Date().timeIntervalSince1970

        let record = ClientRecord(
            clientID: clientID,
            clientName: resolvedName,
            redirectURIs: redirectURIs,
            createdAt: now,
        )

        lock.lock()
        clients[clientID] = record
        saveStateLocked()
        lock.unlock()

        return HTTPResponse.json([
            "client_id": clientID,
            "client_id_issued_at": Int(now),
            "client_name": resolvedName,
            "redirect_uris": redirectURIs,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ], status: 201)
    }

    // MARK: - OAuth 2.1 Authorization Endpoint

    func handleAuthorizeGet(_ request: HTTPRequest) -> HTTPResponse {
        let q = request.query
        guard q["response_type"] == "code" else {
            return oauthError("unsupported_response_type", "Only response_type=code is supported")
        }
        guard let clientID = q["client_id"], !clientID.isEmpty else {
            return oauthError("invalid_request", "Missing client_id")
        }
        guard let redirectURI = q["redirect_uri"], !redirectURI.isEmpty else {
            return oauthError("invalid_request", "Missing redirect_uri")
        }

        lock.lock()
        let client = clients[clientID]
        lock.unlock()

        guard let client else {
            return oauthError("invalid_client", "Unknown client_id")
        }
        guard client.redirectURIs.contains(redirectURI) else {
            return oauthError("invalid_request", "redirect_uri does not match registered URIs")
        }

        let state = q["state"]
        guard let codeChallenge = q["code_challenge"], !codeChallenge.isEmpty,
              q["code_challenge_method"] == "S256"
        else {
            return redirectWithError(
                to: redirectURI,
                error: "invalid_request",
                description: "PKCE with code_challenge_method=S256 is required",
                state: state,
            )
        }

        let scope = (q["scope"]?.isEmpty == false) ? q["scope"]! : "shell"
        let nonce = Self.randomURLSafeToken(byteCount: 24)
        let pending = PendingConsent(
            nonce: nonce,
            clientID: clientID,
            clientName: client.clientName,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge,
            scope: scope,
            expiresAt: Date().timeIntervalSince1970 + Self.consentTTL,
        )

        lock.lock()
        pruneExpiredLocked()
        pendingConsents[nonce] = pending
        lock.unlock()

        return HTTPResponse.html(Self.consentHTML(
            clientName: client.clientName,
            clientID: clientID,
            scope: scope,
            nonce: nonce,
        ))
    }

    func handleAuthorizePost(_ request: HTTPRequest) -> HTTPResponse {
        let form = request.formParameters()
        guard let nonce = form["nonce"], !nonce.isEmpty else {
            return oauthError("invalid_request", "Missing authorization nonce")
        }
        let decision = form["decision"] ?? "deny"

        lock.lock()
        pruneExpiredLocked()
        let pending = pendingConsents.removeValue(forKey: nonce)
        lock.unlock()

        guard let pending else {
            return HTTPResponse.html(
                Self.messageHTML(title: "Session Expired", body: "This authorization request has expired. Please restart OAuth from your MCP client."),
                status: 400,
            )
        }

        guard decision == "approve" else {
            return redirectWithError(
                to: pending.redirectURI,
                error: "access_denied",
                description: "User denied authorization",
                state: pending.state,
            )
        }

        let code = Self.randomURLSafeToken(byteCount: 32)
        let authCode = AuthCode(
            code: code,
            clientID: pending.clientID,
            redirectURI: pending.redirectURI,
            codeChallenge: pending.codeChallenge,
            scope: pending.scope,
            expiresAt: Date().timeIntervalSince1970 + Self.authCodeTTL,
        )

        lock.lock()
        authCodes[code] = authCode
        lock.unlock()

        var components = URLComponents(string: pending.redirectURI)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "code", value: code))
        if let state = pending.state, !state.isEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = items
        guard let destination = components?.url?.absoluteString else {
            return oauthError("server_error", "Failed to construct redirect URI")
        }
        return HTTPResponse.redirect(to: destination)
    }

    // MARK: - Token & Revocation Endpoints

    func handleToken(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse.text("Method not allowed", status: 405, extraHeaders: [("Allow", "POST")])
        }

        let params: [String: String]
        if request.header("content-type")?.lowercased().contains("application/json") == true,
           let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        {
            var dict: [String: String] = [:]
            for (k, v) in json {
                if let s = v as? String { dict[k] = s }
            }
            params = dict
        } else {
            params = request.formParameters()
        }

        let grantType = params["grant_type"] ?? ""
        switch grantType {
        case "authorization_code":
            return exchangeAuthorizationCode(params)
        case "refresh_token":
            return exchangeRefreshToken(params)
        default:
            return oauthError("unsupported_grant_type", "Supported grant_types: authorization_code, refresh_token")
        }
    }

    func handleRevoke(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse.text("Method not allowed", status: 405, extraHeaders: [("Allow", "POST")])
        }
        let params = request.formParameters()
        if let token = params["token"], !token.isEmpty {
            lock.lock()
            tokens.removeAll { Self.constantTimeEqual($0.accessToken, token) || Self.constantTimeEqual($0.refreshToken, token) }
            saveStateLocked()
            lock.unlock()
        }
        return HTTPResponse(status: 200)
    }

    private func exchangeAuthorizationCode(_ params: [String: String]) -> HTTPResponse {
        guard let code = params["code"], !code.isEmpty,
              let verifier = params["code_verifier"], !verifier.isEmpty,
              let redirectURI = params["redirect_uri"], !redirectURI.isEmpty
        else {
            return oauthError("invalid_request", "Missing code, code_verifier, or redirect_uri")
        }

        lock.lock()
        pruneExpiredLocked()
        let entry = authCodes.removeValue(forKey: code)
        lock.unlock()

        guard let entry else {
            return oauthError("invalid_grant", "Invalid or expired authorization code")
        }
        if let clientID = params["client_id"], !clientID.isEmpty, clientID != entry.clientID {
            return oauthError("invalid_grant", "client_id mismatch")
        }
        guard entry.redirectURI == redirectURI else {
            return oauthError("invalid_grant", "redirect_uri mismatch")
        }
        guard Self.verifyPKCE(verifier: verifier, challenge: entry.codeChallenge) else {
            return oauthError("invalid_grant", "PKCE verification failed")
        }

        return issueTokens(clientID: entry.clientID, scope: entry.scope)
    }

    private func exchangeRefreshToken(_ params: [String: String]) -> HTTPResponse {
        guard let refreshToken = params["refresh_token"], !refreshToken.isEmpty else {
            return oauthError("invalid_request", "Missing refresh_token")
        }

        let now = Date().timeIntervalSince1970
        lock.lock()
        guard let index = tokens.firstIndex(where: { Self.constantTimeEqual($0.refreshToken, refreshToken) }) else {
            lock.unlock()
            return oauthError("invalid_grant", "Unknown refresh_token")
        }
        let existing = tokens[index]
        guard existing.refreshExpiresAt > now else {
            tokens.remove(at: index)
            saveStateLocked()
            lock.unlock()
            return oauthError("invalid_grant", "Expired refresh_token")
        }
        if let clientID = params["client_id"], !clientID.isEmpty, clientID != existing.clientID {
            lock.unlock()
            return oauthError("invalid_grant", "client_id mismatch")
        }
        tokens.remove(at: index)
        lock.unlock()

        return issueTokens(clientID: existing.clientID, scope: existing.scope)
    }

    private func issueTokens(clientID: String, scope: String) -> HTTPResponse {
        let now = Date().timeIntervalSince1970
        let record = TokenRecord(
            accessToken: "igvt_" + Self.randomURLSafeToken(byteCount: 32),
            refreshToken: "igvr_" + Self.randomURLSafeToken(byteCount: 32),
            clientID: clientID,
            scope: scope,
            expiresAt: now + Self.accessTokenTTL,
            refreshExpiresAt: now + Self.refreshTokenTTL,
        )

        lock.lock()
        pruneExpiredLocked()
        tokens.append(record)
        saveStateLocked()
        lock.unlock()

        return HTTPResponse.json([
            "access_token": record.accessToken,
            "token_type": "Bearer",
            "expires_in": Int(Self.accessTokenTTL),
            "refresh_token": record.refreshToken,
            "scope": record.scope,
        ])
    }

    // MARK: - Persistence

    private func loadState() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return }
        guard let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        clients = decoded.clients
        tokens = decoded.tokens.filter { $0.refreshExpiresAt > now }
    }

    private func saveStateLocked() {
        guard let stateURL else { return }
        let dir = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = PersistedState(clients: clients, tokens: tokens)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let tmp = dir.appendingPathComponent(".\(stateURL.lastPathComponent).tmp.\(getpid())")
        if FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            _ = rename(tmp.path, stateURL.path)
        }
    }

    private func pruneExpiredLocked() {
        let now = Date().timeIntervalSince1970
        pendingConsents = pendingConsents.filter { $0.value.expiresAt > now }
        authCodes = authCodes.filter { $0.value.expiresAt > now }
        tokens.removeAll { $0.refreshExpiresAt <= now }
    }

    // MARK: - Helpers

    private func oauthError(_ error: String, _ description: String, status: Int = 400) -> HTTPResponse {
        HTTPResponse.json(["error": error, "error_description": description], status: status)
    }

    private func redirectWithError(to redirectURI: String, error: String, description: String, state: String?) -> HTTPResponse {
        var components = URLComponents(string: redirectURI)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "error", value: error))
        items.append(URLQueryItem(name: "error_description", value: description))
        if let state, !state.isEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = items
        guard let destination = components?.url?.absoluteString else {
            return oauthError(error, description)
        }
        return HTTPResponse.redirect(to: destination)
    }

    static func verifyPKCE(verifier: String, challenge: String) -> Bool {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let computed = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return constantTimeEqual(computed, challenge)
    }

    static func randomURLSafeToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isAllowedRedirectURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "javascript" || scheme == "data" || scheme == "file" {
            return false
        }
        if scheme == "http" {
            guard let host = url.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        }
        // https or custom app schemes (e.g. cursor://, vscode://, claude://)
        return !scheme.isEmpty
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func consentHTML(clientName: String, clientID: String, scope: String, nonce: String) -> String {
        let safeName = escapeHTML(clientName)
        let safeID = escapeHTML(clientID)
        let safeScope = escapeHTML(scope)
        let safeNonce = escapeHTML(nonce)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Authorize iGhostVT MCP</title>
        <style>
          :root { color-scheme: light dark; }
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; min-height: 100vh; margin: 0; align-items: center; justify-content: center; background: #f5f5f7; color: #1d1d1f; }
          @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #f5f5f7; } .card { background: #2c2c2e; border-color: #3a3a3c; } .meta { color: #aeaeb2; } }
          .card { max-width: 400px; width: calc(100% - 32px); padding: 24px; border-radius: 14px; background: #fff; border: 1px solid #d2d2d7; box-shadow: 0 8px 30px rgba(0,0,0,.08); }
          h1 { margin: 0 0 8px; font-size: 20px; }
          p { margin: 0 0 16px; line-height: 1.5; font-size: 14px; }
          .meta { font-size: 12px; color: #6e6e73; margin-bottom: 20px; word-break: break-all; }
          .actions { display: flex; gap: 10px; }
          button { flex: 1; padding: 10px 14px; border-radius: 8px; border: 0; font-size: 14px; font-weight: 600; cursor: pointer; }
          .approve { background: #0071e3; color: #fff; }
          .deny { background: rgba(128,128,128,.2); color: inherit; }
        </style>
        </head>
        <body>
        <div class="card">
          <h1>iGhostVT Local Shell</h1>
          <p><strong>\(safeName)</strong> is requesting MCP access to run commands in your local iGhostVT terminal.</p>
          <div class="meta">Client: \(safeID)<br>Scope: \(safeScope)</div>
          <form method="POST" action="/authorize" class="actions">
            <input type="hidden" name="nonce" value="\(safeNonce)">
            <button type="submit" name="decision" value="deny" class="deny">Deny</button>
            <button type="submit" name="decision" value="approve" class="approve">Approve</button>
          </form>
        </div>
        </body>
        </html>
        """
    }

    private static func messageHTML(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(escapeHTML(title))</title></head>
        <body style="font-family:-apple-system,sans-serif;padding:32px;max-width:480px;margin:auto">
        <h2>\(escapeHTML(title))</h2><p>\(escapeHTML(body))</p></body></html>
        """
    }
}
