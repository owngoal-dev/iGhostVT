//
//  CopiedIndicator.swift
//  iGhostVT
//

#if !os(visionOS)
    import SPIndicator
#endif
import UIKit

/// The one confirmation a copy gets: a pasteboard write changes nothing on
/// screen, so without it Copy Text and Copy as Image read as dead menu
/// items even though they worked.
///
/// Presented on the window the command came from — the key window is
/// whichever one the system last focused, which on an iPad with two
/// windows side by side need not be it.
@MainActor
enum CopiedIndicator {
    static func present(in window: UIWindow?) {
        // SPIndicator compiles its views for `os(iOS)` only, so on
        // visionOS the module is empty; the copy itself still happens.
        #if !os(visionOS)
            let indicator = SPIndicatorView(
                title: String(localized: "Copied"),
                preset: .done,
            )
            indicator.presentWindow = window
            indicator.present(haptic: .success)
        #endif
    }
}
