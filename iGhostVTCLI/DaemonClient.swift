import Darwin
import Dispatch
import Foundation
import XPC

/// Not in the iOS SDK (`API_UNAVAILABLE(ios)`), and the CLI builds for both
/// platforms from one source. Declared here rather than shared with the
/// daemon: `iGhostVTDaemonShared` would bring the proxy's socket wire and
/// its logging along with it, and this program needs one symbol.
@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

enum CLIError: Error {
    case usage(String)
    case daemonUnreachable
    case timedOut
    case daemonTooOld
    case refused(iGhostVTReplyCode, String?)
    case sessionLingered(UInt64)

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .daemonUnreachable, .timedOut, .daemonTooOld: 69
        case .refused, .sessionLingered: 1
        }
    }

    var message: String {
        switch self {
        case let .usage(text):
            return text
        case .daemonUnreachable:
            return "The terminal daemon is not running. Open iGhostVT and try again."
        case .timedOut:
            return "The terminal daemon did not respond in time. Try again."
        case .daemonTooOld:
            return "The terminal daemon is out of date. Update iGhostVT and try again."
        case let .refused(code, detail):
            if let detail, !detail.isEmpty {
                return detail
            }
            switch code {
            case .unknownSession: return "No session with that id. Run `ighostvt-cli list` to see them."
            case .sessionBusy: return "The session is already open in another window."
            case .sessionLimitReached: return "The session limit has been reached. Close a session and try again."
            case .spawnFailed: return "The shell could not be started. Check the default shell in iGhostVT Settings."
            case .handshakeRequired, .unsupportedVersion: return "Unable to connect to the terminal daemon. Restart iGhostVT and try again."
            case .invalidRequest: return "The terminal daemon did not accept the request. Try again."
            case .inputBacklog: return "The session's program is not reading its input. Wait for it to catch up and try again."
            case .operationFailed, .success: return "The terminal daemon could not complete the request. Try again."
            }
        case let .sessionLingered(id):
            return "Session \(id) did not exit. Try again."
        }
    }
}

/// One row of `listSessions`.
struct SessionSummary {
    var id: UInt64
    var title: String
    var columns: UInt16
    var rows: UInt16
    var isAttached: Bool
    /// Present from daemons that report them; `nil` from an older one.
    var processName: String?
    var currentDirectory: String?
    /// The directory written against `@jb`, sent only for one inside the
    /// bootstrap — whose real root is a random jbroot under roothide and a
    /// prefix nobody types under rootless.
    var displayDirectory: String?

    /// What `list` prints: the spelling the user's own shell would.
    var listedDirectory: String {
        displayDirectory ?? currentDirectory ?? "-"
    }
}

/// One connection to `ighostvtd`, used for a single command and closed.
///
/// Requests are synchronous and made from the main thread — never from
/// `queue`, which is where libxpc delivers the replies they wait for. The
/// CLI attaches to nothing and so receives no events; a session's output
/// reaches it only as the replay a `snapshotSession` reply carries.
final class DaemonClient {
    private static let requestTimeout: TimeInterval = 6

    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.cli.xpc")
    private var connection: xpc_connection_t?

    /// Creates the connection and completes the handshake every other
    /// request is gated on.
    func connect() throws {
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else {
            throw CLIError.daemonUnreachable
        }
        // libxpc requires a handler before activation. Nothing is expected
        // on it: an error means the daemon went away, and the request in
        // flight then fails on its own.
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        self.connection = connection
        do {
            _ = try request(.hello)
        } catch CLIError.refused, CLIError.timedOut {
            // A refused or unanswered hello is indistinguishable from no
            // daemon at all from here: launchd may have started nothing,
            // or the daemon may have denied this binary and cancelled.
            throw CLIError.daemonUnreachable
        }
    }

    func cancel() {
        guard let connection else { return }
        self.connection = nil
        xpc_connection_cancel(connection)
    }

    /// Sends one request and returns its reply. Bounded: a daemon that has
    /// wedged must not hang the shell that ran this.
    @discardableResult
    func request(
        _ operation: iGhostVTOperation,
        _ fill: (xpc_object_t) -> Void = { _ in },
    ) throws -> xpc_object_t {
        guard let connection else { throw CLIError.daemonUnreachable }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        fill(message)

        let done = DispatchSemaphore(value: 0)
        var received: xpc_object_t?
        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            received = reply
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            throw CLIError.timedOut
        }
        guard let reply = received, xpc_get_type(reply) == iGhostVTXPC.typeDictionary else {
            throw CLIError.daemonUnreachable
        }
        guard xpc_dictionary_get_uint64(reply, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let code = iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code))
        else {
            throw CLIError.daemonUnreachable
        }
        guard code == .success else {
            // A daemon that predates these operations decodes no operation
            // at all and says so; say which side is behind.
            if code == .invalidRequest,
               operation == .snapshotSession || operation == .injectInput
            {
                throw CLIError.daemonTooOld
            }
            throw CLIError.refused(code, Self.string(reply, iGhostVTWireKey.errorMessage))
        }
        return reply
    }

    // MARK: - Reply decoding

    /// `xpc_dictionary_get_string` hands back a pointer the dictionary owns,
    /// so every read converts before the object can be released.
    static func string(_ object: xpc_object_t, _ key: String) -> String? {
        withExtendedLifetime(object) {
            xpc_dictionary_get_string(object, key).map { String(cString: $0) }
        }
    }

    static func data(_ object: xpc_object_t, _ key: String) -> Data? {
        withExtendedLifetime(object) {
            var count = 0
            guard let bytes = xpc_dictionary_get_data(object, key, &count),
                  count > 0, count <= iGhostVTProtocol.maximumMessageDataByteCount
            else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }

    static func sessions(in reply: xpc_object_t) -> [SessionSummary] {
        guard let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.sessions),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return [] }
        var summaries: [SessionSummary] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let row = xpc_array_get_value(array, index)
            summaries.append(
                SessionSummary(
                    id: xpc_dictionary_get_uint64(row, iGhostVTWireKey.sessionID),
                    title: string(row, iGhostVTWireKey.title) ?? "shell",
                    columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(row, iGhostVTWireKey.columns)),
                    rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(row, iGhostVTWireKey.rows)),
                    isAttached: xpc_dictionary_get_bool(row, iGhostVTWireKey.isAttached),
                    processName: string(row, iGhostVTWireKey.processName),
                    currentDirectory: string(row, iGhostVTWireKey.currentDirectory),
                    displayDirectory: string(row, iGhostVTWireKey.displayDirectory),
                ),
            )
        }
        return summaries
    }
}
