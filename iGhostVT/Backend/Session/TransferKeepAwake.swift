import UIKit

/// Keeps the screen from locking while a transfer runs — an `rz`/`sz`, or
/// files dropped on a remote tab on their way over. A locked phone
/// suspends the app soon after, a suspended app's links are down, and the
/// transfer is given up halfway; leaving the app on purpose still has
/// `RemoteBackgroundGrace`. The Mac has no idle lock to hold off.
@MainActor
enum TransferKeepAwake {
    private final class Weak {
        weak var owner: AnyObject?
        init(_ owner: AnyObject) {
            self.owner = owner
        }
    }

    /// Weak, so a tab closed mid-transfer does not hold the screen on.
    private static var active: [ObjectIdentifier: Weak] = [:]

    static func update(_ owner: AnyObject, isTransferring: Bool) {
        #if !targetEnvironment(macCatalyst)
            let id = ObjectIdentifier(owner)
            if isTransferring {
                active[id] = Weak(owner)
            } else {
                active.removeValue(forKey: id)
            }
            active = active.filter { $0.value.owner != nil }
            let keepAwake = !active.isEmpty
            guard UIApplication.shared.isIdleTimerDisabled != keepAwake else { return }
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            AppLog.info(.transport, keepAwake ? "a transfer is running; the screen stays on" : "no transfer left; the screen may lock again")
        #endif
    }
}
