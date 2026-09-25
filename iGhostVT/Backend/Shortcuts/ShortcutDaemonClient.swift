//
//  ShortcutDaemonClient.swift
//  iGhostVT
//

import Darwin
import Dispatch
import Foundation
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

/// Why an intent could not do what it was asked. Every case reads as a
/// sentence in the Shortcuts editor, so each carries its own wording.
enum ShortcutError: Error {
    case daemonUnreachable
    case timedOut
    case unknownSession
    case sessionBusy
    case sessionLimitReached
    /// The session's program is not reading its terminal and the daemon is
    /// already holding all the input it will hold for it.
    case inputBacklog
    case spawnFailed
    case refused(String)
    case sessionLingered
    case commandTimedOut
    case noWindow
}

@available(iOS 16.0, macCatalyst 16.0, *)
extension ShortcutError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .daemonUnreachable:
            "The terminal helper is not running. Open iGhostVT and try again."
        case .timedOut:
            "The terminal helper did not respond in time. Try again."
        case .unknownSession:
            "That terminal session no longer exists."
        case .sessionBusy:
            "That terminal session is already open in another window."
        case .sessionLimitReached:
            "The session limit has been reached. Close a session and try again."
        case .inputBacklog:
            "The session's program is not reading its input. Wait for it to catch up and try again."
        case .spawnFailed:
            "The shell could not be started. Check the default shell in iGhostVT Settings."
        case let .refused(detail):
            "\(detail)"
        case .sessionLingered:
            "The terminal session did not end in time. Try again."
        case .commandTimedOut:
            "The command did not finish in time. Increase the time limit and try again."
        case .noWindow:
            "iGhostVT could not open a window. Try again."
        }
    }
}

/// One daemon session as an intent sees it — a `listSessions` row.
struct ShortcutSession: Sendable, Equatable {
    var id: UInt64
    var title: String
    var columns: UInt16
    var rows: UInt16
    var isAttached: Bool
    var processName: String?
    var foregroundIsShell: Bool?
    var currentDirectory: String?
}

/// The replay a `snapshotSession` reply carries, with the grid it was
/// written on.
struct ShortcutSnapshot: Sendable {
    var columns: UInt16
    var rows: UInt16
    var replay: Data

    /// The grid the replay is rendered on: the session's, or the nominal
    /// one when the daemon reported none.
    var gridColumns: UInt16 {
        columns == 0 ? iGhostVTProtocol.defaultColumns : columns
    }

    var gridRows: UInt16 {
        rows == 0 ? iGhostVTProtocol.defaultRows : rows
    }

    /// The replay rendered the way `ighostvt-cli capture` renders it.
    func text(fullTranscript: Bool) -> String {
        fullTranscript ? transcript().text : render().screenText()
    }

    /// The transcript with the shell's prompt marks, for cutting one
    /// command's output out of it.
    func transcript() -> ScreenRenderer.Transcript {
        render().transcript()
    }

    private func render() -> ScreenRenderer {
        let renderer = ScreenRenderer(columns: gridColumns, rows: gridRows)
        renderer.feed(replay)
        return renderer
    }
}

/// The intents' connection to `ighostvtd`: one per intent run, opened for
/// the few requests the intent makes and closed with it. It is the CLI's
/// client with `async` in place of the semaphore — every request is a
/// one-shot XPC message with a reply, decoded on the connection's queue
/// into a value that can cross to the intent's task.
///
/// It attaches to nothing on purpose (`snapshotSession` and `injectInput`
/// are the whole vocabulary beside list, open, and close), so an intent
/// never takes a session from the tab showing it. The one exception is a
/// session this client *opened*: the daemon attaches a new session to the
/// peer that opened it, and a tab can take it only once that attachment is
/// gone — `detachSession` releases it for certain; `cancel()` does too, but
/// asynchronously, and nothing orders it before the tab's attach.
final class ShortcutDaemonClient: @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 6

    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.shortcuts.xpc", qos: .userInitiated)
    private let lock = NSLock()
    private var connection: xpc_connection_t?

    /// Runs `body` against a connected client and closes the connection
    /// afterwards, whatever `body` did.
    static func withConnection<T: Sendable>(
        _ body: @Sendable (ShortcutDaemonClient) async throws -> T,
    ) async throws -> T {
        let client = ShortcutDaemonClient()
        // Before `connect()`: a hello that is refused or times out throws
        // with the connection already activated, and an activated XPC
        // connection has to be cancelled or it lives on.
        defer { client.cancel() }
        try await client.connect()
        return try await body(client)
    }

    func connect() async throws {
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else {
            throw ShortcutError.daemonUnreachable
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        lock.locked { self.connection = connection }
        do {
            try await request(.hello) { _ in }
        } catch ShortcutError.refused, ShortcutError.timedOut {
            // No daemon and a daemon that denied this binary look the same
            // from here; say the thing the user can act on.
            throw ShortcutError.daemonUnreachable
        }
    }

    func cancel() {
        let connection = lock.locked { () -> xpc_connection_t? in
            defer { self.connection = nil }
            return self.connection
        }
        if let connection {
            xpc_connection_cancel(connection)
        }
    }

    // MARK: - Operations

    func listSessions() async throws -> [ShortcutSession] {
        try await request(.listSessions, decode: Self.sessions(in:))
    }

    func session(_ id: UInt64) async throws -> ShortcutSession {
        guard let session = try await listSessions().first(where: { $0.id == id }) else {
            throw ShortcutError.unknownSession
        }
        return session
    }

    func snapshot(_ id: UInt64) async throws -> ShortcutSnapshot {
        try await request(.snapshotSession, fill: {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, id)
        }, decode: { reply in
            ShortcutSnapshot(
                columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns)),
                rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows)),
                replay: Self.data(reply, iGhostVTWireKey.data) ?? Data(),
            )
        })
    }

    /// Writes `bytes` to the session's PTY as if typed, in order. Chunked
    /// like every other input path; nothing an intent parameter carries
    /// comes near one chunk. Nothing to write is a no-op, as in the app's
    /// transport — the daemon reads a zero-length `data` as absent and
    /// refuses the request.
    func inject(_ bytes: [UInt8], into id: UInt64) async throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        repeat {
            let end = min(bytes.count, offset + iGhostVTProtocol.inputChunkByteCount)
            let chunk = Array(bytes[offset ..< end])
            try await request(.injectInput) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, id)
                chunk.withUnsafeBytes {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count)
                }
            }
            offset = end
        } while offset < bytes.count
    }

    /// Opens a session at a nominal grid — whoever attaches sets the real
    /// one. `command` empty means the daemon's default shell. The session
    /// stays attached to this client until `detachSession` or `cancel()`.
    /// A command with more arguments than the daemon takes is refused
    /// whole, never sent shortened: a trimmed argv is a different command.
    func openSession(command: [String], inheritDirectoryFrom: UInt64?) async throws -> UInt64 {
        guard command.count <= iGhostVTProtocol.maximumCommandArgumentCount else {
            throw ShortcutError.refused(
                String(localized: "Too many arguments. Use at most \(iGhostVTProtocol.maximumCommandArgumentCount)."),
            )
        }
        return try await request(.openSession, fill: { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, UInt64(iGhostVTProtocol.defaultColumns))
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, UInt64(iGhostVTProtocol.defaultRows))
            if !command.isEmpty {
                let arguments = xpc_array_create(nil, 0)
                for argument in command {
                    xpc_array_append_value(arguments, xpc_string_create(argument))
                }
                xpc_dictionary_set_value(message, iGhostVTWireKey.command, arguments)
            }
            if let inheritDirectoryFrom {
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.inheritDirectoryFrom, inheritDirectoryFrom)
            }
        }, decode: { reply in
            xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
        })
    }

    /// Releases this client's attachment to a session it opened. The daemon
    /// detaches before it replies, so once this returns a tab's attach
    /// cannot find the session busy — which `cancel()` alone, asynchronous
    /// and unordered against that attach, does not promise.
    func detachSession(_ id: UInt64) async throws {
        try await request(.detachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, id)
        }
    }

    /// Kills the session and waits for the daemon to report it gone: the
    /// close reply only says the SIGHUP went out, and the shell has the
    /// daemon's grace period to run its exit hooks.
    func closeSession(_ id: UInt64, timeout: TimeInterval = 5) async throws {
        try await request(.closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, id)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await !(listSessions().contains { $0.id == id }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ShortcutError.sessionLingered
    }

    /// Polls until the session's shell is back at its prompt, or the
    /// deadline passes. The daemon rereads the foreground process group as
    /// output drains and on a timer, so a short poll interval buys nothing.
    /// Returns the session's last row; `nil` when the deadline passed first.
    func waitForPrompt(_ id: UInt64, timeout: TimeInterval) async throws -> ShortcutSession? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let session = try await session(id)
            if session.foregroundIsShell == true {
                return session
            }
            if Date() >= deadline {
                return nil
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Requests

    @discardableResult
    private func request(
        _ operation: iGhostVTOperation,
        fill: (xpc_object_t) -> Void = { _ in },
    ) async throws -> Bool {
        try await request(operation, fill: fill, decode: { _ in true })
    }

    /// Sends one request and hands its reply to `decode` on the connection's
    /// queue; only the decoded value crosses to the caller. Bounded: a
    /// wedged daemon must not hang the Shortcuts run past its own limit.
    private func request<T: Sendable>(
        _ operation: iGhostVTOperation,
        fill: (xpc_object_t) -> Void = { _ in },
        decode: @escaping @Sendable (xpc_object_t) -> T,
    ) async throws -> T {
        guard let connection = lock.locked({ self.connection }) else {
            throw ShortcutError.daemonUnreachable
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        fill(message)

        let outcome = FinishOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let queue = self.queue
            queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
                if outcome.finish() {
                    continuation.resume(throwing: ShortcutError.timedOut)
                }
            }
            xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                let result = Self.decodeReply(reply, decode: decode)
                guard outcome.finish() else { return }
                continuation.resume(with: result)
            }
        }
    }

    private static func decodeReply<T>(
        _ reply: xpc_object_t,
        decode: (xpc_object_t) -> T,
    ) -> Result<T, ShortcutError> {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_uint64(reply, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let code = iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code))
        else {
            return .failure(.daemonUnreachable)
        }
        switch code {
        case .success:
            return .success(decode(reply))
        case .unknownSession:
            return .failure(.unknownSession)
        case .sessionBusy:
            return .failure(.sessionBusy)
        case .sessionLimitReached:
            return .failure(.sessionLimitReached)
        case .inputBacklog:
            return .failure(.inputBacklog)
        case .spawnFailed:
            if let detail = string(reply, iGhostVTWireKey.errorMessage), !detail.isEmpty {
                return .failure(.refused(detail))
            }
            return .failure(.spawnFailed)
        case .handshakeRequired, .unsupportedVersion:
            return .failure(.daemonUnreachable)
        case .invalidRequest, .operationFailed:
            if let detail = string(reply, iGhostVTWireKey.errorMessage), !detail.isEmpty {
                return .failure(.refused(detail))
            }
            return .failure(.timedOut)
        }
    }

    // MARK: - Reply decoding

    private static func string(_ object: xpc_object_t, _ key: String) -> String? {
        withExtendedLifetime(object) {
            xpc_dictionary_get_string(object, key).map { String(cString: $0) }
        }
    }

    private static func data(_ object: xpc_object_t, _ key: String) -> Data? {
        withExtendedLifetime(object) {
            var count = 0
            guard let bytes = xpc_dictionary_get_data(object, key, &count),
                  count > 0, count <= iGhostVTProtocol.maximumMessageDataByteCount
            else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }

    private static func bool(_ object: xpc_object_t, _ key: String) -> Bool? {
        guard let value = xpc_dictionary_get_value(object, key),
              xpc_get_type(value) == iGhostVTXPC.typeBool else { return nil }
        return xpc_bool_get_value(value)
    }

    private static func sessions(in reply: xpc_object_t) -> [ShortcutSession] {
        guard let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.sessions),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return [] }
        var rows: [ShortcutSession] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let row = xpc_array_get_value(array, index)
            guard xpc_get_type(row) == iGhostVTXPC.typeDictionary else { continue }
            rows.append(ShortcutSession(
                id: xpc_dictionary_get_uint64(row, iGhostVTWireKey.sessionID),
                title: string(row, iGhostVTWireKey.title) ?? "shell",
                columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(row, iGhostVTWireKey.columns)),
                rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(row, iGhostVTWireKey.rows)),
                isAttached: xpc_dictionary_get_bool(row, iGhostVTWireKey.isAttached),
                processName: string(row, iGhostVTWireKey.processName),
                foregroundIsShell: bool(row, iGhostVTWireKey.foregroundIsShell),
                currentDirectory: string(row, iGhostVTWireKey.currentDirectory),
            ))
        }
        return rows
    }
}

/// A one-shot gate: the reply and the timeout race, and only the first
/// caller through it resumes the continuation.
private final class FinishOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func finish() -> Bool {
        lock.locked {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }
}

/// `NSLock.withLock` is iOS 16; this file compiles for the app's iOS 15
/// floor even though only iOS 16 code ever calls it.
private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
