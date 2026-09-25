import Combine
import SwiftUI

/// The Mac build's first-launch alert: an app opened from Downloads (or a
/// disk image) cannot register its helper — Login Items would bind to a path
/// that is gone by the next launch — so it offers to move itself to
/// Applications and reopen from there. There is no third way: nothing works
/// from here, so the other button quits.
extension View {
    func relocationPrompt(_ agent: MacLaunchAgent) -> some View {
        modifier(WindowAlertPresenter(
            requests: agent.$status
                .removeDuplicates()
                .map { $0 == .needsRelocation ? RelocationRequest() : nil },
            onFinish: {},
            makeAlert: { _, finish in
                let alert = AlertViewController(
                    title: "Move iGhostVT to Applications?",
                    message: """
                    iGhostVT works from your Applications folder, so your \
                    terminals keep running after you close this window. It can \
                    move itself there and reopen.
                    """,
                    actions: [
                        AlertAction("Quit") {
                            finish()
                            agent.quit()
                        },
                        AlertAction("Move", kind: .accent) {
                            finish()
                            agent.moveToApplications()
                        },
                    ],
                )
                // Taken down with its window, this alert's plain answer would
                // quit the app; only the slot has to clear.
                alert.onDismissUnanswered = finish
                return alert
            },
        ))
    }
}

private struct RelocationRequest {}
