import SwiftUI

/// Confirmation for closing a tab with a program running in it. Close is a
/// kill, not a detach: the daemon SIGHUPs the shell and reclaims it moments
/// later, and the ledger entry goes with it, so there is no undo and no
/// reattach. A stray tap on an × must not destroy running work silently —
/// a shell idling at its prompt closes without the question (see
/// `TerminalTab.hasRunningProgram`). A remote tab always asks, and offers
/// to leave its shell running on its host instead.
extension View {
    func closeTabConfirmation(_ tabManager: TabManager) -> some View {
        modifier(WindowAlertPresenter(
            requests: tabManager.$closeRequest,
            onFinish: { tabManager.closeRequest = nil },
            makeAlert: { tab, finish in
                // A remote tab's shell is its host's: let go of it here and
                // the host's own window takes it back, or end it.
                if let hostName = tab.remoteHostName {
                    return AlertViewController(
                        title: "Close “\(tab.displayTitle)”?",
                        message: "The terminal can keep running on “\(hostName)”.",
                        // The two answers first, both filled, the one that
                        // keeps the work leading and Return's default;
                        // Cancel last, and still what a dismissal without
                        // an answer means (the last `.normal` action).
                        actions: [
                            AlertAction("Detach Session", kind: .highlighted) {
                                tabManager.detach(tab)
                                finish()
                            },
                            AlertAction("Terminate Session", kind: .filled) {
                                tabManager.close(tab, from: .confirmation)
                                finish()
                            },
                            AlertAction("Cancel") {
                                finish()
                            },
                        ],
                    )
                }
                // A device is using it: closing ends it there as well.
                if !tab.isRemote, let holder = tab.store.heldBy {
                    return AlertViewController(
                        title: "Close “\(tab.displayTitle)”?",
                        message: "This also ends it on “\(holder)”.",
                        actions: [
                            AlertAction("Cancel") {
                                finish()
                            },
                            AlertAction("Close Tab", kind: .highlighted) {
                                tabManager.close(tab, from: .confirmation)
                                finish()
                            },
                        ],
                    )
                }
                return AlertViewController(
                    title: "Close “\(tab.displayTitle)”?",
                    message: "This closes the tab and stops everything running in it.",
                    actions: [
                        AlertAction("Cancel") {
                            finish()
                        },
                        AlertAction("Close Tab", kind: .highlighted) {
                            tabManager.close(tab, from: .confirmation)
                            finish()
                        },
                    ],
                )
            },
        ))
    }
}
