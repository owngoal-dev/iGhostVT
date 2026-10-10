import Combine
import SwiftUI

/// An update replaced the running copy (`ExecutableWatch`), so this is old
/// code against a daemon the package's postinst has already restarted. The
/// app asks rather than quits: a shell may be in the middle of something.
@MainActor
final class UpdateNotice: ObservableObject {
    static let shared = UpdateNotice()
    @Published var isPending = false
    /// The Mac's own update replaced this copy and the app is already on its
    /// way to the new one (`MacLaunchAgent`): nothing to ask.
    var isRelaunching = false
}

extension View {
    func updatePrompt(_ notice: UpdateNotice) -> some View {
        modifier(WindowAlertPresenter(
            requests: notice.$isPending.map { $0 ? UpdateRequest() : nil },
            onFinish: { notice.isPending = false },
            makeAlert: { _, finish in
                AlertViewController(
                    title: "iGhostVT Was Updated",
                    message: "This is still the old version. Quit iGhostVT and open it again to use the new one.",
                    actions: [
                        AlertAction("Later", handler: finish),
                        AlertAction("Quit", kind: .highlighted) {
                            finish()
                            AppTermination.terminate()
                        },
                    ],
                )
            },
        ))
    }
}

private struct UpdateRequest {}
