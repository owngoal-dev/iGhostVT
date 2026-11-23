import Darwin
import Foundation

/// Top-level HTTP router connecting OAuth 2.1 endpoints, Origin checks, and MCP.
///
/// The server is reached by whatever name the client was given — the
/// loopback address on this device, `<name>.local` or an address from
/// another one — and OAuth's discovery has to name the server back the
/// same way, or a client refuses metadata whose issuer is not the server it
/// asked. So the issuer is read off each request's `Host`, and only a name
/// this server can be reached by on its own is taken: an IP address,
/// `localhost`, or a `.local` name. A web page whose DNS name was pointed
/// at this device (DNS rebinding) arrives under its own name and is turned
/// away before anything is read.
final class MCPRouter {
    let oauth: OAuthStore
    let mcp: MCPHandler
    private let port: UInt16

    init(oauth: OAuthStore, mcp: MCPHandler, port: UInt16) {
        self.oauth = oauth
        self.mcp = mcp
        self.port = port
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard let issuer = issuer(for: request) else {
            return HTTPResponse.text("Unknown host", status: 421)
        }
        // Reject cross-origin browser requests (anti-CSRF / DNS rebinding).
        if let origin = request.header("origin"), !Self.isAllowedOrigin(origin) {
            return HTTPResponse.text("Forbidden origin", status: 403)
        }

        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"),
             ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return oauth.protectedResourceMetadata(issuer: issuer)

        case ("GET", "/.well-known/oauth-authorization-server"):
            return oauth.authorizationServerMetadata(issuer: issuer)

        case ("POST", "/register"):
            return oauth.handleRegister(request)

        case ("GET", "/authorize"):
            return oauth.handleAuthorizeGet(request)

        case ("POST", "/authorize"):
            return oauth.handleAuthorizePost(request)

        case ("GET", "/authorize/status"):
            return oauth.handleAuthorizeStatus(request)

        case ("POST", "/token"):
            return oauth.handleToken(request)

        case ("POST", "/revoke"):
            return oauth.handleRevoke(request)

        case ("GET", "/health"):
            return HTTPResponse.json(["ok": true])

        case (_, "/mcp"):
            guard oauth.isAuthorized(request) else {
                return oauth.unauthorizedResponse(issuer: issuer)
            }
            return mcp.handle(request)

        default:
            return HTTPResponse.text("Not found", status: 404)
        }
    }

    /// `http://` and the request's `Host` as sent — port and letter case
    /// included, since a client may compare the issuer with the address it
    /// was given as a string; the loopback address when there is none
    /// (HTTP/1.0). Nil for a name this server is not reached by.
    private func issuer(for request: HTTPRequest) -> String? {
        guard let host = request.header("host"), !host.isEmpty else {
            return "http://127.0.0.1:\(port)"
        }
        guard let name = Self.hostName(ofAuthority: host), Self.isOwnName(name) else {
            return nil
        }
        return "http://\(host)"
    }

    private static func isAllowedOrigin(_ origin: String) -> Bool {
        let lower = origin.lowercased()
        guard lower != "null", let url = URL(string: lower), url.scheme == "http" || url.scheme == "https",
              let host = url.host
        else { return false }
        return isOwnName(host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host)
    }

    /// The host of a `Host` header: brackets and the port taken off.
    static func hostName(ofAuthority authority: String) -> String? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let rest = authority[authority.index(after: close)...]
            guard rest.isEmpty || (rest.first == ":" && rest.dropFirst().allSatisfy(\.isNumber)) else { return nil }
            return String(authority[authority.index(after: authority.startIndex) ..< close])
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty else { return nil }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isNumber) {
            return nil
        }
        return String(parts[0])
    }

    /// An IP address, `localhost`, or a `.local` name: what reaches this
    /// device without a DNS name anyone else controls.
    static func isOwnName(_ name: String) -> Bool {
        var host = name.lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if host == "localhost" || (host.hasSuffix(".local") && host.count > ".local".count) {
            return true
        }
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}
