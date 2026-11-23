import Darwin
import Dispatch
import Foundation

private struct MCPConfig {
    var host = "127.0.0.1"
    var port: UInt16 = 18765
    var issuer: String?
    var allowAllSessions = false
    var staticToken: String?
    var ephemeral = false
    var stateFile: String?
    var revokeAll = false
    var showHelp = false
}

private func usageText() -> String {
    """
    usage: ighostvt-mcp [serve] [options]
           ighostvt-mcp revoke-all [--state-file <path>]

    Minimalist HTTP MCP server with OAuth 2.1 (PKCE S256 + DCR) backed by ighostvtd.

    options:
      --host <addr>          Bind address (default: 127.0.0.1)
      --port <port>          TCP port (default: 18765)
      --issuer <url>         Public OAuth issuer URL (default: http://<host>:<port>)
      --allow-all-sessions   Allow MCP to view/control non-MCP terminal sessions
      --token <secret>       Optional static Bearer token in addition to OAuth 2.1
      --ephemeral            Keep OAuth clients and tokens in memory only
      --state-file <path>    Path to persist OAuth state (mode 0600)
      -h, --help             Show this help
    """
}

private func parseArgs(_ args: [String]) throws -> MCPConfig {
    var config = MCPConfig()
    var index = 1
    if index < args.count {
        if args[index] == "serve" {
            index += 1
        } else if args[index] == "revoke-all" {
            config.revokeAll = true
            index += 1
        }
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            config.showHelp = true
            index += 1
        case "--allow-all-sessions":
            config.allowAllSessions = true
            index += 1
        case "--ephemeral":
            config.ephemeral = true
            index += 1
        case "--host":
            index += 1
            guard index < args.count else { throw MCPBackendError.invalidArgument("--host requires a value") }
            config.host = args[index]
            index += 1
        case "--port":
            index += 1
            guard index < args.count, let port = UInt16(args[index]) else {
                throw MCPBackendError.invalidArgument("--port requires a valid TCP port (0-65535)")
            }
            config.port = port
            index += 1
        case "--issuer":
            index += 1
            guard index < args.count else { throw MCPBackendError.invalidArgument("--issuer requires a URL") }
            config.issuer = args[index]
            index += 1
        case "--token":
            index += 1
            guard index < args.count else { throw MCPBackendError.invalidArgument("--token requires a value") }
            config.staticToken = args[index]
            index += 1
        case "--state-file":
            index += 1
            guard index < args.count else { throw MCPBackendError.invalidArgument("--state-file requires a path") }
            config.stateFile = args[index]
            index += 1
        default:
            throw MCPBackendError.invalidArgument("Unknown argument: \(arg)")
        }
    }
    return config
}

private func logStderr(_ line: String) {
    if let data = (line + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func run() -> Int32 {
    let config: MCPConfig
    do {
        config = try parseArgs(CommandLine.arguments)
    } catch {
        logStderr("error: \(error.localizedDescription)")
        logStderr(usageText())
        return 64
    }

    if config.showHelp {
        print(usageText())
        return 0
    }

    let stateURL: URL? = if config.ephemeral {
        nil
    } else if let custom = config.stateFile {
        URL(fileURLWithPath: custom)
    } else {
        OAuthStore.defaultStateURL
    }

    if config.revokeAll {
        guard let stateURL else {
            logStderr("error: --ephemeral cannot be combined with revoke-all")
            return 64
        }
        do {
            try OAuthStore.revokeAll(at: stateURL)
            logStderr("Revoked all saved OAuth clients and tokens at \(stateURL.path)")
            return 0
        } catch {
            logStderr("error: \(error.localizedDescription)")
            return 1
        }
    }

    let displayHost = (config.host == "0.0.0.0" || config.host == "::") ? "127.0.0.1" : config.host
    let issuer = config.issuer ?? "http://\(displayHost):\(config.port)"
    let oauth = OAuthStore(issuer: issuer, stateURL: stateURL, staticToken: config.staticToken)
    let backend = DaemonShellBackend()
    let mcp = MCPHandler(backend: backend, allowAllSessions: config.allowAllSessions)
    let router = MCPRouter(oauth: oauth, mcp: mcp)

    let server = LocalHTTPServer(host: config.host, port: config.port) { request in
        router.handle(request)
    }

    do {
        try server.start()
    } catch {
        logStderr("error: failed to start MCP HTTP server: \(error.localizedDescription)")
        return 69
    }

    let boundIssuer = config.issuer ?? "http://\(displayHost):\(server.boundPort)"
    logStderr("ighostvt-mcp listening on http://\(config.host):\(server.boundPort)")
    logStderr("  MCP endpoint:   \(boundIssuer)/mcp")
    logStderr("  OAuth metadata: \(boundIssuer)/.well-known/oauth-authorization-server")
    logStderr("  Session scope:  \(config.allowAllSessions ? "all sessions" : "MCP-created sessions only")")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = {
        server.stop()
        exit(0)
    }
    sigint.setEventHandler(handler: shutdown)
    sigterm.setEventHandler(handler: shutdown)
    sigint.resume()
    sigterm.resume()

    dispatchMain()
}

exit(run())
