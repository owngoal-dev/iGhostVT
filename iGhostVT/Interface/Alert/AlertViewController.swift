//
//  AlertViewController.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// The app's replacement for `UIAlertController` (and the SwiftUI `.alert`
/// that wraps it): the same `AlertCardView` that `SessionStatusOverlay` draws
/// inline, presented over a dimmed pane with a cross-dissolve. Every action
/// dismisses the alert before its handler runs.
///
/// Title and message are `String.LocalizationValue`, so call sites keep
/// passing literals — including interpolated ones like `"Close “\(name)”?"`,
/// whose key stays `Close “%@”?` — and localization keeps working implicitly,
/// exactly as it did in `.alert`'s `LocalizedStringKey` positions.
final class AlertViewController: OverlayPanelController {
    private let alertTitle: String
    private let alertMessage: String
    private let actions: [AlertAction]
    private var hasAnswered = false

    /// Runs when something other than a button takes the alert down — the
    /// cover it was presented on dismissed under it (⇧⌘\ under a
    /// confirmation), or its window closed. Without it no action runs and
    /// the presenter's slot stays busy for the window's life. The plain
    /// action by default, which is the cancel in every confirmation; an
    /// alert whose plain answer does something (the relocation prompt's
    /// Quit) sets its own.
    var onDismissUnanswered: (() -> Void)?

    init(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        actions: [AlertAction],
    ) {
        alertTitle = String(localized: title)
        alertMessage = String(localized: message)
        self.actions = actions
        onDismissUnanswered = actions.first { $0.kind == .normal }?.handler
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let dismissing = actions.map { action in
            AlertAction(verbatim: action.title, kind: action.kind) { [weak self] in
                self?.answer(action)
            }
        }
        install(AlertPane(title: alertTitle, message: alertMessage, actions: dismissing))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !hasAnswered, isBeingDismissed || presentingViewController == nil else { return }
        hasAnswered = true
        onDismissUnanswered?()
    }

    private func answer(_ action: AlertAction) {
        guard !hasAnswered else { return }
        hasAnswered = true
        dismiss(animated: true, completion: action.handler)
    }
}

private struct AlertPane: View {
    let title: String
    let message: String
    let actions: [AlertAction]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            AlertCardView(title: title, message: message, actions: actions)
                .padding(DS.Padding.l)
        }
    }
}
