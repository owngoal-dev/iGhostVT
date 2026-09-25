//
//  ShareSheet.swift
//  iGhostVT
//

import UIKit

/// The system share sheet for a file, presented from the window's front-most
/// context — the one UIKit presentation SwiftUI menus reach for (a tab's
/// Export Text…, the log viewer's Share).
@MainActor
enum ShareSheet {
    /// Presents after a menu's dismissal animation: presenting into it
    /// leaves a dead sheet (the switcher's settings entry hit the same
    /// race). A key command pays the same wait; it is too short to notice.
    static func present(_ url: URL, in window: UIWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            presentNow(url, in: window)
        }
    }

    private static func presentNow(_ url: URL, in window: UIWindow?) {
        guard let window, var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil,
        )
        // iPad and the Mac require an anchor or the presentation crashes;
        // the menu that triggered this is gone, so anchor to the window.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(
                x: window.bounds.midX,
                y: window.bounds.midY,
                width: 1,
                height: 1,
            )
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
