import Darwin
import Foundation
import notify
import XPC

/// What each subcommand does. Every one of them opens a connection, says
/// hello, asks its question, and goes away — the CLI attaches to nothing,
/// so a session the app is showing keeps its tab while this runs.
enum Commands {
    static func list() throws {
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        let sessions = try DaemonClient.sessions(in: client.request(.listSessions))
        guard !sessions.isEmpty else { return }

        var table: [[String]] = [["SID", "PROCESS", "SIZE", "ATTACHED", "LOCK", "CWD"]]
        for session in sessions {
            table.append([
                String(session.id),
                session.processName ?? session.title,
                "\(session.columns)x\(session.rows)",
                session.isAttached ? "yes" : "no",
                session.lock ?? "-",
                session.listedDirectory,
            ])
        }
        printTable(table)
    }

    static func capture(sessionID: UInt64, full: Bool) throws {
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        let reply = try client.request(.snapshotSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }
        let columns = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns))
        let rows = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows))
        let renderer = ScreenRenderer(
            columns: columns == 0 ? iGhostVTProtocol.defaultColumns : columns,
            rows: rows == 0 ? iGhostVTProtocol.defaultRows : rows,
        )
        if let replay = DaemonClient.data(reply, iGhostVTWireKey.data) {
            renderer.feed(replay)
        }
        let text = full ? renderer.transcriptText() : renderer.screenText()
        if !text.isEmpty {
            print(text)
        }
    }

    static func send(sessionID: UInt64, input: [UInt8]) throws {
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        // One message per chunk, in order — the daemon buffers what the
        // program has not read yet. Nothing a user types on a command line
        // comes near one chunk; a `text` argument read from a file might.
        // Nothing to send (`text ""`) is a no-op, as in the app: the daemon
        // reads a zero-length `data` as absent and refuses the request.
        guard !input.isEmpty else { return }
        var offset = 0
        repeat {
            let end = min(input.count, offset + iGhostVTProtocol.inputChunkByteCount)
            let chunk = Array(input[offset ..< end])
            try client.request(.injectInput) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
                chunk.withUnsafeBytes {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count)
                }
            }
            offset = end
        } while offset < input.count
    }

    static func new(command: [String], options: NewOptions) throws {
        let isRemote = DaemonTarget.hostSelector != nil
        var directory = options.directory
        if let given = directory {
            if isRemote {
                guard given.hasPrefix("/") else { throw CLIError.usage("--cwd on a host takes a full path there.") }
            } else {
                directory = try canonicalDirectory(given)
            }
        }
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        if let source = options.directorySessionID {
            // The daemon starts in the home when the session is gone;
            // asked for by id, a wrong id is a mistake to report.
            let sessions = try DaemonClient.sessions(in: client.request(.listSessions))
            guard sessions.contains(where: { $0.id == source }) else {
                throw CLIError.refused(.unknownSession, nil)
            }
        }
        let reply = try client.request(.openSession) { message in
            // A nominal grid unless one is given: nothing here is going to
            // display the session, and whoever attaches sets the real size.
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, UInt64(options.columns ?? iGhostVTProtocol.defaultColumns))
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, UInt64(options.rows ?? iGhostVTProtocol.defaultRows))
            if let directory {
                xpc_dictionary_set_string(message, iGhostVTWireKey.startDirectory, directory)
            }
            if let source = options.directorySessionID {
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.inheritDirectoryFrom, source)
            }
            if !options.environment.isEmpty {
                let environment = xpc_dictionary_create(nil, nil, 0)
                for (name, value) in options.environment {
                    xpc_dictionary_set_string(environment, name, value)
                }
                xpc_dictionary_set_value(message, iGhostVTWireKey.environment, environment)
            }
            if let shell = options.shell {
                xpc_dictionary_set_string(message, iGhostVTWireKey.shell, shell)
            }
            guard !command.isEmpty else { return }
            let arguments = xpc_array_create(nil, 0)
            for argument in command {
                xpc_array_append_value(arguments, xpc_string_create(argument))
            }
            xpc_dictionary_set_value(message, iGhostVTWireKey.command, arguments)
        }
        let sessionID = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
        if let lock = options.lock {
            try client.request(.setSessionAttributes) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
                let attributes = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(attributes, iGhostVTSessionAttribute.lock, lock)
                xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, attributes)
            }
        }
        if isRemote || options.attaches {
            // A new session is attached to whoever opened it. This device's
            // daemon lets go the moment the CLI leaves; a host holds a
            // device's sessions for a while after its link drops, as for a
            // phone that will be back, and the app here cannot attach to
            // one this connection still holds — so it is let go of in words.
            try client.request(.detachSession) {
                xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
            }
        }
        print(sessionID)
        fflush(stdout)
        if options.attaches {
            try attachInApp(sessionID: sessionID, client: client)
        }
    }

    private static func canonicalDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw CLIError.usage("No directory at \(path).") }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CLIError.usage("No directory at \(path).")
        }
        return String(cString: resolved)
    }

    static func attachInApp(sessionID: UInt64) throws {
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        try attachInApp(sessionID: sessionID, client: client)
    }

    /// The app is told by a notification whose state is the id. A state
    /// holds one id, and another `app attach` can replace it before the app
    /// reads it, so it is posted again until the session is attached.
    private static func attachInApp(sessionID: UInt64, client: DaemonRequester) throws {
        func session() throws -> SessionSummary {
            let sessions = try DaemonClient.sessions(in: client.request(.listSessions))
            guard let session = sessions.first(where: { $0.id == sessionID }) else {
                throw CLIError.refused(.unknownSession, nil)
            }
            return session
        }
        _ = try session()
        var token: Int32 = 0
        guard notify_register_check(iGhostVTProtocol.showSessionNotification, &token) == NOTIFY_STATUS_OK else {
            throw CLIError.appDidNotAttach
        }
        defer { notify_cancel(token) }
        let deadline = Date().addingTimeInterval(5)
        var nextPost = Date.distantPast
        while true {
            if Date() >= nextPost {
                notify_set_state(token, sessionID)
                notify_post(iGhostVTProtocol.showSessionNotification)
                nextPost = Date().addingTimeInterval(1.5)
            }
            usleep(100_000)
            if try session().isAttached {
                return
            }
            guard Date() < deadline else { throw CLIError.appDidNotAttach }
        }
    }

    static func kill(sessionID: UInt64) throws {
        let client = try DaemonTarget.connect()
        defer { client.cancel() }
        try client.request(.closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }
        // The reply says the SIGHUP went out, not that the shell is gone —
        // it gets a grace period to run its exit hooks before the daemon
        // kills it. Wait for the session to actually leave the list, the
        // way the app does as it quits.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let sessions = try DaemonClient.sessions(in: client.request(.listSessions))
            if !sessions.contains(where: { $0.id == sessionID }) {
                return
            }
            usleep(100_000)
        }
        throw CLIError.sessionLingered(sessionID)
    }
}

/// Prints rows as columns two spaces apart, the first row a header.
func printTable(_ table: [[String]]) {
    guard let header = table.first else { return }
    let widths = (0 ..< header.count).map { column in table.map { $0[column].count }.max() ?? 0 }
    for row in table {
        var line = ""
        for (column, field) in row.enumerated() {
            line += field
            // Padded by hand: `padding(toLength:)` measures — and cuts — in
            // UTF-16 units, and a name outside the BMP would lose its last
            // character to it.
            if column < row.count - 1 {
                line += String(repeating: " ", count: max(0, widths[column] + 2 - field.count))
            }
        }
        print(line.trimmedTrailingSpaces())
    }
}

private extension String {
    func trimmedTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") {
            text.removeLast()
        }
        return text
    }
}
