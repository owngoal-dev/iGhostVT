//
//  DaemonSessionDirectory.swift
//  iGhostVT
//

import Foundation

/// The app's window onto the daemon's session registry. The daemon is the
/// only book of record — the app persists nothing about sessions and asks
/// (`listSessions`) whenever it needs the truth: cold-launch reattach, the
/// Live Activity's detached count, anything else that used to guess from a
/// UserDefaults ledger.
@MainActor
final class DaemonSessionDirectory {
    static let shared = DaemonSessionDirectory()

    /// Last answer the daemon gave. Purely a cache of the last `refresh()`;
    /// never persisted.
    private(set) var sessions: [XPCDaemonTransport.SessionSummary] = []

    private var hasClaimedResumable = false

    /// Sessions the app has asked the daemon to kill but whose death a
    /// `listSessions` reply has not yet confirmed. A reply issued before the
    /// kill lands still carries the dying session; without this filter that
    /// stale row re-enters the cache as a phantom detached shell and — with
    /// nothing left to trigger another refresh — pins the Live Activity
    /// forever.
    private var pendingKills: Set<UInt64> = []

    private init() {}

    /// The daemon sessions no peer is attached to, and the ones a paired
    /// device has open (shown here as held there), for the first window of
    /// a cold launch to adopt. One caller holds the claim at a time; every
    /// later window starts fresh, mirroring the old ledger's claim semantics
    /// without the ledger — until the holder's tabs detach
    /// (`releaseResumableClaim`), when its shells are unattached again and
    /// the next window to ask adopts them.
    /// `answered` is false when the daemon gave no answer — the claim
    /// then stays open for a retry, and the empty list means nothing.
    func claimResumable(completion: @escaping @MainActor @Sendable (_ ids: [UInt64], _ answered: Bool) -> Void) {
        guard !hasClaimedResumable else {
            completion([], false)
            return
        }
        hasClaimedResumable = true
        XPCDaemonTransport.listSessions { rows in
            Task { @MainActor in
                // No answer is not "nothing to resume": a daemon still
                // starting (the Mac's helper before it is allowed) holds the
                // last run's shells all the same, and the claim stays open
                // for the retry once it answers (`TabManager.resumeLeftovers`).
                let answered = rows != nil
                if !answered {
                    self.hasClaimedResumable = false
                }
                let rows = rows ?? []
                self.sessions = rows
                completion(rows.filter { !$0.isAttached || $0.holder != nil }.map(\.id), answered)
            }
        }
    }

    /// The window that held the claim detached its tabs. Without this the
    /// shells it left in the daemon are unreachable from any tab until the
    /// process dies: iOS disconnects a backgrounded scene and builds a new
    /// one — with a new `TabManager` — on return, in the same process.
    func releaseResumableClaim() {
        hasClaimedResumable = false
    }

    /// The tab just told the daemon to kill this session: drop it from the
    /// cache right now, so the caller's very next Live Activity refresh sees
    /// the truth instead of waiting an XPC round-trip — closing the last tab
    /// must collapse the activity immediately, not after the reply.
    func evict(_ id: UInt64) {
        pendingKills.insert(id)
        sessions.removeAll { $0.id == id }
    }

    /// Re-ask the daemon and notify the Live Activity when the answer moved.
    /// An unreachable daemon holds no sessions anyone can attach to, so a nil
    /// reply empties the cache instead of preserving it — the old behavior
    /// left the activity advertising detached shells forever.
    func refresh() {
        XPCDaemonTransport.listSessions { rows in
            Task { @MainActor in
                var rows = rows ?? []
                self.pendingKills.formIntersection(rows.map(\.id))
                rows.removeAll { self.pendingKills.contains($0.id) }
                guard rows != self.sessions else { return }
                self.sessions = rows
                SessionActivityController.shared.refresh()
            }
        }
    }
}
