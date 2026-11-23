import Darwin
import Dispatch
import Foundation

/// `ighostvt-mcp`: the MCP server `MCPSupervisor` in the daemon's proxy runs
/// while Settings ▸ Advanced ▸ MCP Server is on. It listens on every address
/// (`MCPConsent.port`) and serves this device and the local network only,
/// drops to the session user first on the device, and exits when the daemon
/// goes — run by hand it is not the daemon's child, the daemon admits none of
/// its connections, and it exits at once.
private struct MCPConfig {
    var port: UInt16 = MCPConsent.port
    var ephemeral = false
    var stateFile: String?
    var forget = false
    var revokeAll = false
    var showHelp = false
}

private func usageText() -> String {
    """
    usage: ighostvt-mcp serve [--forget] [--port <port>] [--state-file <path> | --ephemeral]
           ighostvt-mcp revoke-all [--state-file <path>]

    The MCP server iGhostVT runs while Settings, Advanced, MCP Server is on.
    It serves this device and the local network, and a client is let in only
    when the iGhostVT app allows it.

    options:
      --forget               Forget every authorized client before serving
      --port <port>          TCP port (default: \(MCPConsent.port))
      --ephemeral            Keep OAuth clients and tokens in memory only
      --state-file <path>    Where to keep OAuth state (mode 0600)
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
        case "--ephemeral":
            config.ephemeral = true
            index += 1
        case "--forget":
            config.forget = true
            index += 1
        case "--port":
            index += 1
            guard index < args.count, let port = UInt16(args[index]) else {
                throw MCPBackendError.invalidArgument("--port requires a valid TCP port (0-65535)")
            }
            config.port = port
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
    if let data = ("ighostvt-mcp: " + line + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

/// The device's daemon is root, and nothing here needs it: the server
/// becomes mobile — the user the sessions run as — before it reads a byte
/// from the network or opens its state. The Mac's agent already is the user.
private func dropToSessionUser() -> Bool {
    guard getuid() == 0 || geteuid() == 0 else { return true }
    guard let entry = getpwnam("mobile") else { return false }
    let uid = entry.pointee.pw_uid
    let gid = entry.pointee.pw_gid
    var groups = [gid_t(gid)]
    guard setgroups(1, &groups) == 0,
          setgid(gid) == 0,
          setuid(uid) == 0,
          setuid(0) != 0
    else { return false }
    if let home = entry.pointee.pw_dir {
        setenv("HOME", home, 1)
    }
    setenv("USER", "mobile", 1)
    return true
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
    guard dropToSessionUser() else {
        logStderr("error: could not drop to the session user")
        return 77
    }

    let stateURL: URL? = if config.ephemeral {
        nil
    } else if let custom = config.stateFile {
        URL(fileURLWithPath: custom)
    } else {
        OAuthStore.defaultStateURL
    }

    if config.revokeAll || config.forget, let stateURL {
        do {
            try OAuthStore.revokeAll(at: stateURL)
            logStderr("forgot every authorized client")
        } catch {
            logStderr("error: \(error.localizedDescription)")
            return 1
        }
        if config.revokeAll {
            return 0
        }
    }

    // Held for as long as this runs; without it nothing below could reach
    // the daemon anyway.
    guard DaemonShellBackend.holdDaemon(onLost: {
        logStderr("the daemon closed its connection, exiting")
        exit(0)
    }) else {
        logStderr("error: the daemon did not admit this process; it runs only as iGhostVT's own MCP server")
        return 69
    }

    let backend = DaemonShellBackend()
    let oauth = OAuthStore(stateURL: stateURL, authority: backend)
    let router = MCPRouter(
        oauth: oauth,
        mcp: MCPHandler(backend: backend, allowAllSessions: false),
        port: config.port,
    )
    let server = LocalHTTPServer(port: config.port) { request in
        router.handle(request)
    }
    do {
        try server.start()
    } catch {
        logStderr("error: failed to start MCP HTTP server: \(error.localizedDescription)")
        return 69
    }
    logStderr("listening on port \(server.boundPort), path /mcp")

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
