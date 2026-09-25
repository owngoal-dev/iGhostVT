import Combine
import SwiftUI
import UIKit

/// Tracks software keyboard visibility so the Safari-style bottom bar can
/// step aside while typing.
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

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let visible = Self.isSoftwareKeyboard(notification)
                guard self?.isVisible != visible else { return }
                withAnimation(DS.Motion.smooth) {
                    self?.isVisible = visible
                }
            }
            .store(in: &cancellables)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation(DS.Motion.smooth) {
                    self?.isVisible = false
                }
            }
            .store(in: &cancellables)
    }

    private static func isSoftwareKeyboard(_ notification: Notification) -> Bool {
        #if os(visionOS)
            // The visionOS keyboard is its own window; the frame says nothing.
            return true
        #else
            guard
                let value = notification
                .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
            else { return true }
            let screenBounds = UIScreen.main.bounds
            let visibleHeight = value.cgRectValue
                .intersection(screenBounds).height
            // The accessory bar tops out well under 100pt; any real keyboard
            // (even the floating one collapsed to a toolbar does not post here)
            // is far taller.
            return visibleHeight > 100
        #endif
    }
}
