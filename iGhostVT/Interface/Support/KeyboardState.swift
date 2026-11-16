import Combine
import SwiftUI
import UIKit

/// Tracks the software keyboard so the Safari-style bottom bar can step
/// aside while typing, and how far the keyboard reaches into the window,
/// so the layout can keep the terminal above it itself.
///
/// "Software keyboard" is deliberate: with a hardware keyboard attached, iOS
/// still posts keyboardWillShow for the accessory bar alone. Treating that
/// as a keyboard would hide the bottom bar — and since tap-to-dismiss is
/// disabled for hardware keyboards (resigning would kill their input), the
/// tab switcher would become unreachable on compact width. Only a frame
/// tall enough to hold actual keys counts.
@MainActor
final class KeyboardState: ObservableObject {
    @Published private(set) var isVisible = false

    /// How much of the window, above its bottom safe area, the keyboard
    /// covers — the accessory bar alone included. Moves in the keyboard's
    /// own animation, so a layout that follows it moves with the keys.
    @Published private(set) var overlap: CGFloat = 0

    /// The keyboard was announced away from the screen's bottom edge —
    /// floating, split, or as an empty frame — and `overlap` is the
    /// accessory bar found docked under it. Only then does a regular-width
    /// layout keep the terminal above the keyboard itself; otherwise it
    /// leaves that to SwiftUI's own avoidance, as it always has. That
    /// avoidance takes a floating keyboard's height off the bottom wherever
    /// the keys float, but it follows a docked keyboard and the accessory
    /// bar on every show, which this type does not: on iOS 27 the bar a
    /// hardware keyboard leaves is announced, after its first show, with
    /// nothing that places it, and a layout padded by `overlap` alone left
    /// the bar over the terminal's last rows.
    @Published private(set) var isUndocked = false

    /// Only the accessory bar is up — a hardware keyboard — so the bottom
    /// bar stays and sits on top of it. Read from where the keyboard is
    /// going, never from where it is: a keyboard on its way down is not an
    /// accessory bar, and the bar that rode down on it read as a glitch.
    var showsAccessoryBarOnly: Bool {
        !isVisible && overlap > 0
    }

    /// The window the overlap is measured against. Set by the view that
    /// owns this state, which learns its window a moment after it is on
    /// screen — a keyboard raised at launch can be announced first, and
    /// is measured again here, or the terminal would sit under it until
    /// the keyboard next moved.
    weak var window: UIWindow? {
        didSet {
            guard window !== oldValue, let lastScreenFrame else { return }
            (isVisible, overlap, isUndocked) = measure(lastScreenFrame, isSettled: true)
        }
    }

    /// The frame UIKit last announced, in screen coordinates.
    private var lastScreenFrame: CGRect?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        for (name, isSettled) in [
            (UIResponder.keyboardWillChangeFrameNotification, false),
            (UIResponder.keyboardDidChangeFrameNotification, true),
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.keyboardFrameChanged(notification, isSettled: isSettled)
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Both values change in one transaction, in the keyboard's own curve.
    /// They used to change apart — the bar on a spring of its own, the
    /// terminal on SwiftUI's keyboard avoidance — and the two animations
    /// played against each other: the bar rode up on the keys before it
    /// went, and the terminal's bottom edge jumped twice.
    private func keyboardFrameChanged(_ notification: Notification, isSettled: Bool) {
        let info = notification.userInfo
        guard let screenFrame = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        lastScreenFrame = screenFrame
        let (visible, overlap, undocked) = measure(screenFrame, isSettled: isSettled)
        guard visible != isVisible || overlap != self.overlap || undocked != isUndocked else { return }
        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(Self.keyboardAnimation(duration: duration)) {
            isVisible = visible
            self.overlap = overlap
            isUndocked = undocked
        }
    }

    private func measure(
        _ screenFrame: CGRect,
        isSettled: Bool,
    ) -> (isVisible: Bool, overlap: CGFloat, isUndocked: Bool) {
        if isDocked(screenFrame) {
            return (isSoftwareKeyboard(screenFrame), overlap(of: screenFrame), false)
        }
        guard let bar = dockedAccessoryBar(under: screenFrame, isSettled: isSettled) else {
            return (false, 0, false)
        }
        return (false, overlap(of: bar), true)
    }

    private func isDocked(_ screenFrame: CGRect) -> Bool {
        guard let screen = window?.windowScene?.screen else { return false }
        let onScreen = screenFrame.intersection(screen.bounds)
        return !onScreen.isEmpty && onScreen.maxY >= screen.bounds.maxY - 1
    }

    /// A floating or split keyboard leaves the accessory bar docked, and
    /// announces its own frame or an empty one, never the bar's.
    private func dockedAccessoryBar(under screenFrame: CGRect, isSettled: Bool) -> CGRect? {
        guard let window, let screen = window.windowScene?.screen else { return nil }
        let floats = !screenFrame.intersection(screen.bounds).isEmpty
        guard floats || (screenFrame.isEmpty && isSettled),
              let bar = window.firstResponderView?.inputAccessoryView, bar.window != nil
        else { return nil }
        let frame = bar.convert(bar.bounds, to: screen.coordinateSpace)
        return frame.maxY >= screen.bounds.maxY - window.safeAreaInsets.bottom - 1 ? frame : nil
    }

    /// A docked frame in the window, less the window's own bottom safe
    /// area, which the layout already keeps clear.
    private func overlap(of screenFrame: CGRect) -> CGFloat {
        guard let window, let screen = window.windowScene?.screen else { return 0 }
        let frame = window.convert(screenFrame, from: screen.coordinateSpace)
        let covered = window.bounds.maxY - max(frame.minY, window.bounds.minY)
        guard frame.width > 0, frame.height > 0, covered > 0 else { return 0 }
        return max(0, covered - window.safeAreaInsets.bottom)
    }

    /// UIKit's keyboard curve is a private spring (curve 7); this is the
    /// spring it is known to match. A zero duration is a frame change that
    /// is not animated.
    private static func keyboardAnimation(duration: Double) -> Animation? {
        guard duration > 0 else { return nil }
        return .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)
    }

    /// The frame is in the coordinates of the screen this window is on, so
    /// that is the screen it is clipped against — never `UIScreen.main`,
    /// which on a phone with two displays can be the other one: clipped to
    /// the outer display's bounds, the keys on the inner one read as an
    /// accessory bar. No window yet means no screen to measure against;
    /// the window's arrival measures the last frame again.
    private func isSoftwareKeyboard(_ screenFrame: CGRect) -> Bool {
        guard let screen = window?.windowScene?.screen else { return false }
        let visibleHeight = screenFrame.intersection(screen.bounds).height
        // The accessory bar tops out well under 100pt; any real keyboard
        // (even the floating one collapsed to a toolbar does not post here)
        // is far taller.
        return visibleHeight > 100
    }
}

private extension UIView {
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderView { return found }
        }
        return nil
    }
}
