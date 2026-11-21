import Darwin
import Foundation

// A one-shot client of `ighostvtd`: it lists the daemon's sessions, reads
// what one is showing, types into one, opens one, or closes one, or manages
// this device's remote access, and exits. With `--host` the session
// commands go to a paired host's daemon instead, over the link the app uses.
// It never attaches — a session the app has open keeps its tab while this
// runs, and nothing here takes over the terminal it was run from.

let usage = """
usage: ighostvt-cli [--host <host>] list
       ighostvt-cli [--host <host>] capture <sid> [--full]
       ighostvt-cli [--host <host>] send <sid> (text <string> | key <name>)...
       ighostvt-cli [--host <host>] new [<option> ...] [-- <command> [argument ...]]
       ighostvt-cli [--host <host>] kill <sid>
       ighostvt-cli app attach <sid>
       ighostvt-cli hosts [--nearby]
       ighostvt-cli pair <host> [<code>]
       ighostvt-cli remote [status]
       ighostvt-cli remote (on | off)
       ighostvt-cli remote pair [--wait | --end]
       ighostvt-cli remote revoke <device-id>
       ighostvt-cli remote name <name>
       ighostvt-cli remote relay (<file.vtrpsc> | --remove)
       ighostvt-cli update [--check]
       ighostvt-cli drop [--relay <file.vtrpsc>] [ls]
       ighostvt-cli drop [--relay <file.vtrpsc>] put <file>...
       ighostvt-cli drop [--relay <file.vtrpsc>] get <file>... [-o <path>] [-f]
       ighostvt-cli drop [--relay <file.vtrpsc>] rm <file>...

  list          show the daemon's sessions: id, foreground process, size,
                whether it is attached, the tab's lock, and the shell's
                directory
  capture       print the session's screen as text; --full also prints the
                scrollback above it
  send          send input to the session, in order. Key names follow tmux's
                send-keys: \(KeyNames.vocabulary)
  new           start a session and print its id, running the shell or the
                given command; it stays open for iGhostVT to show
    --cols <n>, --rows <n>
                its terminal's size until a tab attaches (\(iGhostVTProtocol.defaultColumns) and \(iGhostVTProtocol.defaultRows)
                when not given); --size <cols>x<rows> gives both
    --cwd <directory>
                start there instead of the home; on a host, a full path
                there
    --cwd-of <sid>
                start where that session's shell is now
    --env <NAME>=<VALUE>
                set a variable in its environment; may be repeated
    --shell <path>
                run that shell as a login shell, with shell integration,
                where a command after -- is run as it stands
    --lock (\(iGhostVTSessionAttribute.interactionLock) | \(iGhostVTSessionAttribute.keyboardLock))
                the lock its tab comes up with
    --attach    show it in iGhostVT at once, as app attach does; this
                device only
  kill          close a session and wait for it to exit
  app attach    show a session of this device in iGhostVT, which must be
                running: its tab comes to the front, made if no window has
                one
  --host        run the command on a paired host instead of this device,
                named by its name, id, or address; IGHOSTVT_HOST does the
                same. The hosts are the ones iGhostVT is paired with
  hosts         list the paired hosts; --nearby lists the hosts offering
                remote access on this network and at the relay
  pair          pair with a host found nearby or at the relay, with the
                code it shows (`ighostvt-cli remote pair` there); read
                from the terminal when not given. iGhostVT lists it too
  remote        this device's remote access:
    status      whether it is on, this host's name and id, the relay, the
                open pairing code, and the paired devices
    on, off     turn remote access on or off; on waits for it to listen
    pair        open a pairing window and print its code, which works for
                \(Int(RemoteAccess.pairingWindowSeconds / 60)) minutes whether or not this waits. --wait
                stays until a device pairs and closes the window if
                interrupted; --end closes it
    revoke      forget a paired device; its key stops working at once
    name        what other devices call this one; an empty name goes back to
                the device's own
    relay       use this relay configuration (Mac only), as importing it in
                iGhostVT does; --remove stops using a relay
  update        install the latest release over this copy (Mac only): the
                notarized download, only when its signature names this
                copy's team. iGhostVT relaunches and every session on the
                Mac ends. --check only says whether there is one

  drop          files on the relay, for every device that uses it: put
                uploads (compressed), get downloads into the current folder
                or -o, keeping the file's permissions and time (-f replaces
                one that exists), rm removes, ls lists. A file is named by
                its id, the start of it, or its name. The relay keeps a file
                for 30 minutes after the last device that put or got it
                disconnected, and forgets every file when it restarts. A
                put or get that was cut off resumes when run again. The
                relay is iGhostVT's own; --relay names another
                configuration. Files cross the relay compressed but not
                encrypted

On the Mac, run it as the user iGhostVT runs for, never as root. --host,
hosts and pair read iGhostVT's own pairings, and need that user everywhere.
"""

enum Command {
    case help
    case list
    case capture(sessionID: UInt64, full: Bool)
    case send(sessionID: UInt64, input: [UInt8])
    case new(command: [String], options: NewOptions)
    case kill(sessionID: UInt64)
    case appAttach(sessionID: UInt64)
    case remote(RemoteCommand)
    case update(checkOnly: Bool)
    case hosts(nearby: Bool)
    case pair(selector: String, code: String?)
    case drop(DropCommand, relayPath: String?)

    /// The session commands, which `--host` sends elsewhere; everything
    /// else is about this device.
    var takesHost: Bool {
        switch self {
        case .list, .capture, .send, .new, .kill: true
        case .help, .appAttach, .remote, .update, .hosts, .pair, .drop: false
        }
    }
}

/// What `new` was asked for besides its command.
struct NewOptions {
    static let maximumEnvironmentCount = 64
    static let maximumEnvironmentByteCount = 16 * 1024

    var columns: UInt16?
    var rows: UInt16?
    var directory: String?
    var directorySessionID: UInt64?
    var environment: [String: String] = [:]
    var shell: String?
    var lock: String?
    var attaches = false
}

/// `new`'s options, taken off the front of `arguments`; a later one
/// replaces an earlier one. What is left is the command.
func parseNewOptions(_ arguments: inout [String]) throws -> NewOptions {
    let sizeMistake = CLIError.usage(
        "The new command takes --cols <1-\(iGhostVTProtocol.maximumColumns)>, --rows <1-\(iGhostVTProtocol.maximumRows)> or --size <cols>x<rows>.",
    )
    func count(_ text: Substring, upTo limit: UInt16) throws -> UInt16 {
        guard let value = UInt16(text), (1 ... limit).contains(value) else { throw sizeMistake }
        return value
    }
    var options = NewOptions()
    while let option = arguments.first, option.hasPrefix("-"), option != "--" {
        arguments.removeFirst()
        if option == "--attach" {
            options.attaches = true
            continue
        }
        guard ["--cols", "--rows", "--size", "--cwd", "--cwd-of", "--env", "--shell", "--lock"].contains(option) else {
            throw CLIError.usage("The new command has no option \(option).")
        }
        guard !arguments.isEmpty else { throw CLIError.usage("\(option) needs a value.") }
        let value = arguments.removeFirst()
        switch option {
        case "--cols":
            options.columns = try count(value[...], upTo: iGhostVTProtocol.maximumColumns)
        case "--rows":
            options.rows = try count(value[...], upTo: iGhostVTProtocol.maximumRows)
        case "--size":
            let parts = value.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw sizeMistake }
            options.columns = try count(parts[0], upTo: iGhostVTProtocol.maximumColumns)
            options.rows = try count(parts[1], upTo: iGhostVTProtocol.maximumRows)
        case "--cwd":
            guard !value.isEmpty else { throw CLIError.usage("--cwd takes a directory.") }
            options.directory = value
        case "--cwd-of":
            guard let id = UInt64(value), id > 0 else {
                throw CLIError.usage("--cwd-of takes a session id. Run `ighostvt-cli list` to see them.")
            }
            options.directorySessionID = id
        case "--env":
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                throw CLIError.usage("--env takes NAME=VALUE.")
            }
            options.environment[String(value[..<equals])] = String(value[value.index(after: equals)...])
        case "--shell":
            guard value.hasPrefix("/") else { throw CLIError.usage("--shell takes a shell's full path, such as /bin/zsh.") }
            options.shell = value
        default:
            guard [iGhostVTSessionAttribute.interactionLock, iGhostVTSessionAttribute.keyboardLock].contains(value) else {
                throw CLIError.usage(
                    "--lock takes \(iGhostVTSessionAttribute.interactionLock) or \(iGhostVTSessionAttribute.keyboardLock).",
                )
            }
            options.lock = value
        }
    }
    guard options.directory == nil || options.directorySessionID == nil else {
        throw CLIError.usage("The new command takes --cwd or --cwd-of, not both.")
    }
    let environmentByteCount = options.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    guard options.environment.count <= NewOptions.maximumEnvironmentCount,
          environmentByteCount <= NewOptions.maximumEnvironmentByteCount
    else {
        throw CLIError.usage(
            "The new command takes at most \(NewOptions.maximumEnvironmentCount) --env variables, \(NewOptions.maximumEnvironmentByteCount / 1024) KiB in all.",
        )
    }
    return options
}

func parseSessionID(_ text: String?, _ what: String) throws -> UInt64 {
    guard let text, let id = UInt64(text), id > 0 else {
        throw CLIError.usage("The \(what) command needs a session id. Run `ighostvt-cli list` to see them.")
    }
    return id
}

func parse(_ arguments: [String]) throws -> Command {
    guard let verb = arguments.first else { throw CLIError.usage(usage) }
    let rest = Array(arguments.dropFirst())
    switch verb {
    case "list", "ls":
        guard rest.isEmpty else { throw CLIError.usage("The list command takes no arguments.") }
        return .list
    case "capture":
        let id = try parseSessionID(rest.first, "capture")
        let flags = Array(rest.dropFirst())
        guard flags.allSatisfy({ $0 == "--full" }) else {
            throw CLIError.usage("The capture command takes a session id and an optional --full.")
        }
        return .capture(sessionID: id, full: flags.contains("--full"))
    case "send":
        let id = try parseSessionID(rest.first, "send")
        var input: [UInt8] = []
        var remaining = Array(rest.dropFirst())
        guard !remaining.isEmpty else {
            throw CLIError.usage("The send command takes text <string> or key <name>.")
        }
        while !remaining.isEmpty {
            let kind = remaining.removeFirst()
            guard let value = remaining.first else {
                throw CLIError.usage("Missing a value. The send command takes text <string> or key <name>.")
            }
            remaining.removeFirst()
            switch kind {
            case "text":
                input.append(contentsOf: Array(value.utf8))
            case "key":
                guard let bytes = KeyNames.bytes(for: value) else {
                    throw CLIError.usage("No key named \(value). Known keys: \(KeyNames.vocabulary)")
                }
                input.append(contentsOf: bytes)
            default:
                throw CLIError.usage("The send command takes text <string> or key <name>, not \(kind).")
            }
        }
        return .send(sessionID: id, input: input)
    case "new":
        var command = rest
        let options = try parseNewOptions(&command)
        if command.first == "--" {
            command.removeFirst()
        }
        // Refused whole, never sent shortened: a trimmed argv is a
        // different command, run without a word of complaint.
        guard command.count <= iGhostVTProtocol.maximumCommandArgumentCount else {
            throw CLIError.usage(
                "The new command takes at most \(iGhostVTProtocol.maximumCommandArgumentCount) arguments.",
            )
        }
        guard options.shell == nil || command.isEmpty else {
            throw CLIError.usage("The new command takes --shell or a command, not both.")
        }
        return .new(command: command, options: options)
    case "kill":
        return try .kill(sessionID: parseSessionID(rest.first, "kill"))
    case "app":
        guard rest.count == 2, rest[0] == "attach" else {
            throw CLIError.usage("The app command takes attach <sid>.")
        }
        return try .appAttach(sessionID: parseSessionID(rest[1], "app attach"))
    case "remote":
        return try .remote(parseRemote(rest))
    case "update":
        switch rest {
        case []: return .update(checkOnly: false)
        case ["--check"]: return .update(checkOnly: true)
        default: throw CLIError.usage("The update command takes an optional --check.")
        }
    case "hosts":
        switch rest {
        case []: return .hosts(nearby: false)
        case ["--nearby"]: return .hosts(nearby: true)
        default: throw CLIError.usage("The hosts command takes an optional --nearby.")
        }
    case "pair":
        guard (1 ... 2).contains(rest.count), let selector = rest.first, !selector.hasPrefix("-") else {
            throw CLIError.usage("The pair command takes a host and an optional code. Run `ighostvt-cli hosts --nearby` to see them.")
        }
        return .pair(selector: selector, code: rest.count == 2 ? rest[1] : nil)
    case "drop":
        let (command, relayPath) = try DropCommands.parse(rest)
        return .drop(command, relayPath: relayPath)
    case "-h", "--help", "help":
        return .help
    default:
        throw CLIError.usage("No command named \(verb)\n\n\(usage)")
    }
}

func parseRemote(_ arguments: [String]) throws -> RemoteCommand {
    let rest = Array(arguments.dropFirst())
    func noArguments(_ command: RemoteCommand) throws -> RemoteCommand {
        guard rest.isEmpty else { throw CLIError.usage("The remote \(arguments[0]) command takes no arguments.") }
        return command
    }
    switch arguments.first {
    case nil, "status":
        return try noArguments(.status)
    case "on":
        return try noArguments(.enable(true))
    case "off":
        return try noArguments(.enable(false))
    case "pair":
        switch rest {
        case []: return .pair(wait: false)
        case ["--wait"]: return .pair(wait: true)
        case ["--end"]: return .endPairing
        default: throw CLIError.usage("The remote pair command takes --wait or --end.")
        }
    case "revoke":
        guard rest.count == 1, let deviceID = rest.first, !deviceID.isEmpty else {
            throw CLIError.usage("The remote revoke command needs a device id. Run `ighostvt-cli remote status` to see them.")
        }
        return .revoke(deviceID: deviceID)
    case "name":
        guard rest.count == 1, let name = rest.first else {
            throw CLIError.usage("The remote name command takes one name; \"\" goes back to the device's own.")
        }
        return .rename(name)
    case "relay":
        guard rest.count == 1, let argument = rest.first else {
            throw CLIError.usage("The remote relay command takes a .vtrpsc file or --remove.")
        }
        if argument == "--remove" {
            return .relay(path: nil)
        }
        guard !argument.hasPrefix("-") else {
            throw CLIError.usage("The remote relay command takes a .vtrpsc file or --remove.")
        }
        return .relay(path: argument)
    case let verb?:
        throw CLIError.usage("No remote command named \(verb)\n\n\(usage)")
    }
}

func fail(_ error: Error) -> Never {
    let cliError = error as? CLIError
    let message = cliError?.message ?? "\(error)"
    FileHandle.standardError.write(Data("ighostvt-cli: \(message)\n".utf8))
    exit(cliError?.exitCode ?? 1)
}

// A write to a closed pipe (`ighostvt-cli capture 1 | head`) has to be an
// error this program sees, not a signal that kills it mid-print.
signal(SIGPIPE, SIG_IGN)

/// `--host <host>` (or `--host=<host>`) ahead of the command, and whether
/// it was given there rather than taken from `IGHOSTVT_HOST`; the rest of
/// the arguments.
func parseHost(_ arguments: [String]) throws -> (host: String?, named: Bool, rest: [String]) {
    var rest = arguments
    let first = rest.first ?? ""
    if first == "--host" || first.hasPrefix("--host=") {
        rest.removeFirst()
        var value = String(first.dropFirst("--host=".count))
        if !first.hasPrefix("--host=") {
            value = rest.first ?? ""
            if !rest.isEmpty {
                rest.removeFirst()
            }
        }
        guard !value.isEmpty else { throw CLIError.usage("--host needs a host.") }
        return (value, true, rest)
    }
    let environment = ProcessInfo.processInfo.environment["IGHOSTVT_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    return (environment, false, rest)
}

do {
    let (host, named, arguments) = try parseHost(Array(CommandLine.arguments.dropFirst()))
    let command = try parse(arguments)
    if let host {
        if command.takesHost {
            DaemonTarget.hostSelector = host
        } else if named {
            // The environment applies where it can and is ignored
            // elsewhere; asked for on the command line, it is a mistake.
            throw CLIError.usage("--host applies to list, capture, send, new and kill.")
        }
        if case let .new(_, options) = command, options.attaches {
            throw CLIError.usage("--attach shows a session of this device, not one on a host.")
        }
    }
    switch command {
    case .help:
        // Asked for, so it is the output, not a complaint about the input.
        print(usage)
    case .list:
        try Commands.list()
    case let .capture(sessionID, full):
        try Commands.capture(sessionID: sessionID, full: full)
    case let .send(sessionID, input):
        try Commands.send(sessionID: sessionID, input: input)
    case let .new(command, options):
        try Commands.new(command: command, options: options)
    case let .kill(sessionID):
        try Commands.kill(sessionID: sessionID)
    case let .appAttach(sessionID):
        try Commands.attachInApp(sessionID: sessionID)
    case let .remote(command):
        try RemoteCommands.run(command)
    case let .update(checkOnly):
        try UpdateCommand.run(checkOnly: checkOnly)
    case let .hosts(nearby):
        try nearby ? HostCommands.nearby() : HostCommands.list()
    case let .pair(selector, code):
        try HostCommands.pair(selector: selector, code: code)
    case let .drop(command, relayPath):
        try DropCommands.run(command, relayPath: relayPath)
    }
    exit(0)
} catch {
    fail(error)
}
