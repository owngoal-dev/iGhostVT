import Foundation

/// Where the bytes on the wire come from and go to.
///
/// The terminal surface itself is host-managed (libghostty's in-memory
/// backend); a transport is the other half of that contract — it carries the
/// byte stream to whatever produces it. Today that is the daemon transport
/// over XPC; an SSH channel implements the same protocol later without
/// touching the UI or session layers.
protocol TerminalTransport: AnyObject {
    /// Single event stream. Delivered on an arbitrary transport-owned queue;
    /// hop to the main actor before touching UI state.
    ///
    /// Delivering `.connected` re-enters the transport on the same call
    /// stack: the host answers it with `updateViewport` before returning.
    /// Emit it outside any lock `updateViewport` takes.
    var onEvent: (@Sendable (TerminalTransportEvent) -> Void)? { get set }

    var endpointDescription: String { get }

    /// `takingOver`: a session another peer holds is taken from it rather
    /// than reported held elsewhere — the user asked to use it here.
    func connect(takingOver: Bool)

    /// Bytes typed into (or pasted into) the terminal.
    func send(_ data: Data)

    /// The terminal grid changed size. The daemon transport sends a `resize`;
    /// an SSH transport maps it to a window-change request.
    ///
    /// Called before `connect()` with the grid the session should start at,
    /// on every change after, and once more from inside the delivery of
    /// `.connected`, so a size reported during the connection round trip
    /// still reaches the session. The host makes these calls from whatever
    /// thread it is on — the one that measured the grid, or the transport's
    /// own emitting thread — under the lock that keeps them in order: the
    /// implementation must not block and must not call back into the host
    /// synchronously. Sizes may repeat; one the endpoint already holds
    /// should be dropped.
    func updateViewport(columns: Int, rows: Int)

    /// Replaces what the endpoint keeps on the session for the host — the
    /// tab's lock — so a later attach can hand it back. Fire and forget:
    /// a failure is the transport's to log, and the host keeps its own
    /// copy either way. A backend that keeps nothing ignores it, as does
    /// one with no session to put it on yet.
    func setSessionAttributes(_ attributes: [String: String])

    func disconnect()
}

extension TerminalTransport {
    func connect() {
        connect(takingOver: false)
    }
}

enum TerminalTransportEvent: Sendable {
    case state(TerminalTransportState)
    /// Bytes from the endpoint. `replay` marks the one-shot scrollback a
    /// reattach repaints (historical output, not live protocol) — a ZMODEM
    /// endpoint must render it without scanning it for a transfer trigger, or
    /// an old `rz`/`sz` frame still in the buffer starts a bogus transfer.
    case received(Data, replay: Bool)
    /// The endpoint reports which process is in the foreground on the
    /// terminal ("zsh", "vim"), and whether that process is the session's
    /// own shell — nothing running in front of it. A backend that cannot
    /// know simply never sends it.
    case processName(String, isShell: Bool)
    /// The endpoint reports where the session's shell is — once when the
    /// session is opened or reattached, and again whenever it moves. Only
    /// changes are sent, so each one is a visit the recent list can count.
    case currentDirectory(TerminalDirectory)
    /// What the endpoint keeps on the session (`setSessionAttributes`),
    /// stated once each time the session is opened (`isResumed` false, and
    /// empty) or reattached (`isResumed` true, as last set). A backend that
    /// keeps nothing never sends it, and the host's copy is all there is.
    case sessionAttributes([String: String], isResumed: Bool)
    /// The endpoint refused input because the program is not reading it:
    /// what was pasted from that point on is gone. Sent once per paste.
    case inputRefused
    /// Sent right after `.state(.connected)`: whether the link attached to
    /// the session it had before (true) or opened a fresh one. A download
    /// cut by the last link carries on only in the session it ran in.
    case sessionResumed(Bool)
}

enum TerminalTransportState: Sendable, Equatable {
    case connecting
    case connected
    /// The link died without the session ending — the endpoint may still
    /// hold the session, so a reconnect can reattach and resume. Distinct
    /// from `disconnected`, which is final: the session ended or the
    /// connection was refused, and only the user can ask for another.
    case interrupted(reason: String?)
    case disconnected(reason: String?)
    /// The session lives, but another peer has it: an attach found it
    /// held, or another took it from this one. `holder` names the device
    /// when there is one. Not a failure — the tab offers to take it back.
    case heldElsewhere(holder: String?)
}
