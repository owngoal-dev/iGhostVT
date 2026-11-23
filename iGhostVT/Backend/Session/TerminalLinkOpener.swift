import Foundation
import UIKit

/// Where a link activated in a terminal goes: a tap on it or the touch
/// menu's Open Link on iPhone and iPad (libghostty-spm 2.2.2026112303), a
/// ⌘-click anywhere. Ghostty opens nothing by itself here — on iOS and
/// Catalyst its own opener refuses every link it finds in the terminal —
/// so the host takes each one (`TerminalViewState.onOpenURL`).
///
/// Only a web link leaves the app, in the system's browser. The link is
/// whatever the program printed, an OSC 8 one's target included, and a
/// tap that reached `tel:`, `shortcuts:` or another app's scheme would act
/// on the device. Anything else goes back to Ghostty, which opens nothing,
/// so a tap on a file path still raises the keyboard as a tap on text does.
enum TerminalLinkOpener {
    /// `true` when the link was opened, as `onOpenURL` wants it.
    @MainActor
    static func open(_ link: String) -> Bool {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
