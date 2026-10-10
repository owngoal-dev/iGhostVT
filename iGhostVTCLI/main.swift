import Darwin
import Foundation

// A one-shot client of `ighostvtd`: it lists the daemon's sessions, reads
// what one is showing, types into one, opens one, or closes one, or manages
// this device's remote access, and exits.
// It never attaches — a session the app has open keeps its tab while this
// runs, and nothing here takes over the terminal it was run from.

let usage = """
usage: ighostvt-cli list
       ighostvt-cli capture <sid> [--full]
       ighostvt-cli send <sid> (text <string> | key <name>)...
       ighostvt-cli new [-- <command> [argument ...]]
       ighostvt-cli kill <sid>
       ighostvt-cli remote [status]
       ighostvt-cli remote (on | off)
       ighostvt-cli remote pair [--wait | --end]
       ighostvt-cli remote revoke <device-id>
       ighostvt-cli remote name <name>
       ighostvt-cli remote relay (<file.vtrpsc> | --remove)
       ighostvt-cli update [--check]

  list          show the daemon's sessions: id, foreground process, size,
                whether it is attached, the tab's lock, and the shell's
                directory
  capture       print the session's screen as text; --full also prints the
                scrollback above it
  send          send input to the session, in order. Key names follow tmux's
                send-keys: \(KeyNames.vocabulary)
  new           start a session and print its id, running the shell or the
                given command; it stays open for iGhostVT to show
  kill          close a session and wait for it to exit
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

On the Mac, run it as the user iGhostVT runs for, never as root.
"""

enum Command {
    case help
    case list
    case capture(sessionID: UInt64, full: Bool)
    case send(sessionID: UInt64, input: [UInt8])
    case new(command: [String])
    case kill(sessionID: UInt64)
    case remote(RemoteCommand)
    case update(checkOnly: Bool)
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
        return .new(command: command)
    case "kill":
        return try .kill(sessionID: parseSessionID(rest.first, "kill"))
    case "remote":
        return try .remote(parseRemote(rest))
    case "update":
        switch rest {
        case []: return .update(checkOnly: false)
        case ["--check"]: return .update(checkOnly: true)
        default: throw CLIError.usage("The update command takes an optional --check.")
        }
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

do {
    switch try parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        // Asked for, so it is the output, not a complaint about the input.
        print(usage)
    case .list:
        try Commands.list()
    case let .capture(sessionID, full):
        try Commands.capture(sessionID: sessionID, full: full)
    case let .send(sessionID, input):
        try Commands.send(sessionID: sessionID, input: input)
    case let .new(command):
        try Commands.new(command: command)
    case let .kill(sessionID):
        try Commands.kill(sessionID: sessionID)
    case let .remote(command):
        try RemoteCommands.run(command)
    case let .update(checkOnly):
        try UpdateCommand.run(checkOnly: checkOnly)
    }
    exit(0)
} catch {
    fail(error)
}
