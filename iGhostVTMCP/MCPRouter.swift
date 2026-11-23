import Foundation

/// Top-level HTTP router connecting OAuth 2.1 endpoints, Origin checks, and MCP.
final class MCPRouter {
    let oauth: OAuthStore
    let mcp: MCPHandler
    private let allowedOriginPrefix: String

    init(oauth: OAuthStore, mcp: MCPHandler) {
        self.oauth = oauth
        self.mcp = mcp
        self.allowedOriginPrefix = oauth.issuer.lowercased()
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        // Reject cross-origin browser requests (anti-CSRF / DNS rebinding).
        if let origin = request.header("origin"), !isAllowedOrigin(origin) {
            return HTTPResponse.text("Forbidden origin", status: 403)
        }

        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"),
             ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return oauth.protectedResourceMetadata()

        case ("GET", "/.well-known/oauth-authorization-server"):
            return oauth.authorizationServerMetadata()

        case ("POST", "/register"):
            return oauth.handleRegister(request)

        case ("GET", "/authorize"):
            return oauth.handleAuthorizeGet(request)

        case ("POST", "/authorize"):
            return oauth.handleAuthorizePost(request)

        case ("POST", "/token"):
            return oauth.handleToken(request)

        case ("POST", "/revoke"):
            return oauth.handleRevoke(request)

        case ("GET", "/health"):
            return HTTPResponse.json(["ok": true])

        case (_, "/mcp"):
            guard oauth.isAuthorized(request) else {
                return oauth.unauthorizedResponse()
            }
            return mcp.handle(request)

        default:
            return HTTPResponse.text("Not found", status: 404)
        }
    }

    private func isAllowedOrigin(_ origin: String) -> Bool {
        let lower = origin.lowercased()
        if lower == "null" { return false }
        if lower == allowedOriginPrefix { return true }
        guard let url = URL(string: lower), let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}
