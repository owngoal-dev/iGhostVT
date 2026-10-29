import Foundation

/// How much of its session's output a tab's terminal holds, counted in
/// bytes from the session's first (`iGhostVTWireKey.outputOffset`).
///
/// Kept by the tab across its transports: one link drops, the next names
/// this on its attach, and the host hands back only what the terminal
/// missed — exactly, with no gap and nothing printed twice — instead of
/// a screen rebuilt over what is already there. In memory only: a terminal
/// made at launch holds nothing of any session, so a cold launch asks for
/// the rebuild. One session at a time, and only while every byte the
/// transport took went into this terminal.
final class SessionOutputPosition: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionID: UInt64?
    private var offset: UInt64 = 0

    /// Where the terminal stands in `sessionID`'s output, if it holds it.
    func offset(in sessionID: UInt64?) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let sessionID, self.sessionID == sessionID else { return nil }
        return offset
    }

    /// The host said where the session's output stands after what it just
    /// handed over. `nil` — a host from before offsets — forgets.
    func set(sessionID: UInt64, offset: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        guard let offset else {
            self.sessionID = nil
            return
        }
        self.sessionID = sessionID
        self.offset = offset
    }

    /// Output the terminal took after that.
    func advance(sessionID: UInt64, by count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionID == sessionID else { return }
        offset &+= UInt64(count)
    }
}
