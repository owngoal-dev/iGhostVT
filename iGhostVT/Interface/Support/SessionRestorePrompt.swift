import SwiftUI

/// The launch's question about what the last run left (`SessionRestore`),
/// asked over the window that claimed it. Restore sits on the right, as
/// every alert's default does, and is Return's;
/// a window closed without an answer restores, since Discard ends shells
/// and must never be what nobody chose.
extension View {
    func sessionRestorePrompt(_ tabManager: TabManager) -> some View {
        modifier(WindowAlertPresenter(
            requests: tabManager.$restoreOffer,
            onFinish: {},
            makeAlert: { offer, finish in
                let message: String = switch offer.terminals {
                case .local:
                    String(localized: "\(offer.count) terminals from the last time iGhostVT was open are still running.")
                case .remote:
                    String(localized: "\(offer.count) terminals on your other devices were open the last time you used this app.")
                }
                let alert = AlertViewController(
                    content: AlertViewController.Content(
                        title: String(localized: "Restore Previous Session?"),
                        message: message,
                    ),
                    actions: [
                        AlertAction("Discard") {
                            tabManager.declineRestoreOffer()
                            finish()
                        },
                        AlertAction("Restore", kind: .highlighted) {
                            tabManager.acceptRestoreOffer()
                            finish()
                        },
                    ],
                )
                alert.onDismissUnanswered = {
                    tabManager.acceptRestoreOffer()
                    finish()
                }
                return alert
            },
        ))
    }
}
