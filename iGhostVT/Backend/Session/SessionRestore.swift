//
//  SessionRestore.swift
//  iGhostVT
//

import Foundation

/// The question a cold launch asks when the last run left terminals
/// behind — after ⌘Q (Keep Sessions Running keeps every session for this),
/// a force-quit, or the system ending the app: bring them back as tabs, or
/// let them go.
///
/// Asked once per process, by the window that answers first, and only of
/// what that run left: a scene iOS rebuilds on the way back from the
/// background claims its own run's tabs again and must not ask about them.
/// A terminal a paired device is using is never in the question — it is
/// that device's, and it comes back as a held tab either way.
@MainActor
enum SessionRestore {
    private(set) static var hasAsked = false

    /// Whether this launch still has its question to ask; true once.
    static func takeQuestion() -> Bool {
        guard !hasAsked else { return false }
        hasAsked = true
        return true
    }

    /// A launch's answer to "restore the last session?", waiting on the
    /// window that asked.
    struct Offer: Equatable {
        enum Terminals: Equatable {
            /// This device's daemon sessions no tab holds.
            case local([UInt64])
            /// Ghost Remote's tabs on paired devices (`RemoteTabLedger`),
            /// and which of them was in front.
            case remote([RemoteTabLedger.Entry], activeIndex: Int?)
        }

        let terminals: Terminals
        /// Whether a window left empty by Discard opens a fresh tab
        /// (`SessionLaunch`).
        let opensFreshTab: Bool

        var count: Int {
            switch terminals {
            case let .local(ids): ids.count
            case let .remote(entries, _): entries.count
            }
        }
    }
}
