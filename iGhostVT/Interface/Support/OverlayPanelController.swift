//
//  OverlayPanelController.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// A SwiftUI pane presented over the whole window with a cross-dissolve —
/// the presentation `AlertViewController` established, shared with the
/// Mac's settings panel. `.overFullScreen` keeps the presenter's view in
/// place under the dim, so nothing underneath re-lays out or flashes the
/// way a Catalyst sheet does on its way in and out.
///
/// Subclasses call `install(_:)` from `viewDidLoad` with the pane to host;
/// it is pinned edge to edge and given the interface text size, since a
/// hosting controller starts from a fresh environment.
class OverlayPanelController: UIViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    /// False once the panel no longer wants to appear — an alert closed
    /// while its presentation was still waiting for the context above it.
    var wantsPresentation: Bool {
        true
    }

    func install(_ pane: some View) {
        let host = UIHostingController(rootView: pane.interfaceTextSize().interfaceAccent().interfaceAppearance())
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Presents on the window's front-most presentation context, so a panel
    /// raised while a sheet or full-screen cover is up lands above it instead
    /// of failing on a covered presenter.
    ///
    /// A context on its way out is waited for, and the walk re-run once it
    /// has gone — or stayed: UIKit defers a presentation made under a
    /// dismissing sheet, but drops it without a word when the user cancels
    /// that dismissal (the sheet dragged, then let snap back), and the
    /// front-most context is then the sheet itself. A context on its way in
    /// is waited for the same way. An alert already up is dismissed before
    /// another is shown, never covered by it.
    func present(in window: UIWindow?) {
        guard wantsPresentation, var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            guard !presented.isBeingDismissed else {
                if let coordinator = presented.transitionCoordinator {
                    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                        self?.present(in: window)
                    }
                    return
                }
                break
            }
            // Alerts never stack: the one up is taken down first — as
            // unanswered, so its plain action runs — and this one follows.
            if self is AlertViewController, presented is AlertViewController {
                presented.dismiss(animated: true) { [weak self] in
                    self?.present(in: window)
                }
                return
            }
            presenter = presented
        }
        // A context still on its way in — the settings sheet a relay file
        // just opened — refuses to present over itself until it has arrived.
        if presenter.isBeingPresented, let coordinator = presenter.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.present(in: window)
            }
            return
        }
        presenter.present(self, animated: true)
    }
}
