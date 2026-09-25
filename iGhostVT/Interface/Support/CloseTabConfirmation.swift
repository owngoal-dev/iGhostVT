import SwiftUI

/// Confirmation for closing a tab with a program running in it. Close is a
/// kill, not a detach: the daemon SIGHUPs the shell and reclaims it moments
/// later, and the ledger entry goes with it, so there is no undo and no
/// reattach. A stray tap on an × must not destroy running work silently —
/// a shell idling at its prompt closes without the question (see
/// `TerminalTab.hasRunningProgram`).
extension View {
    func closeTabConfirmation(_ tabManager: TabManager) -> some View {
        modifier(WindowAlertPresenter(
            requests: tabManager.$closeRequest,
            onFinish: { tabManager.closeRequest = nil },
            makeAlert: { tab, finish in
                AlertViewController(
                    title: "Close “\(tab.displayTitle)”?",
                    message: "This closes the tab and stops everything running in it.",
                    actions: [
                        AlertAction("Cancel") {
                            finish()
                        },
                        AlertAction("Close Tab", kind: .destructive) {
                            tabManager.close(tab)
                            finish()
                        },
                    ],
                )
            },
        ))
    }
}
