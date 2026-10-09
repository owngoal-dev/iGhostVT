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
    /// What the card says. Fixed for an ordinary alert; a running task's
    /// alert (`init(content:actions:)`) changes it in place, and `close`
    /// takes it down when the task is done.
    final class Content: ObservableObject {
        @Published var title: String
        @Published var message: String
        @Published var progress: AlertProgress?

        init(title: String, message: String = "", progress: AlertProgress? = nil) {
            self.title = title
            self.message = message
            self.progress = progress
        }
    }

    private let content: Content
    private let actions: [AlertAction]
    private var hasAnswered = false

    /// Runs when something other than a button takes the alert down — the
    /// cover it was presented on dismissed under it (⇧⌘\ under a
    /// confirmation), or its window closed. Without it no action runs and
    /// the presenter's slot stays busy for the window's life. The last
    /// plain action by default, which is the cancel in every confirmation
    /// (a remote tab's Terminate Session before it is `.filled`); an
    /// alert whose plain answer does something (the relocation prompt's
    /// Quit) sets its own.
    var onDismissUnanswered: (() -> Void)?

    convenience init(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        actions: [AlertAction],
    ) {
        self.init(
            content: Content(title: String(localized: title), message: String(localized: message)),
            actions: actions,
        )
    }

    /// An alert whose text and progress follow `content`. Localize its
    /// strings where they are set.
    init(content: Content, actions: [AlertAction]) {
        self.content = content
        self.actions = actions
        onDismissUnanswered = actions.last { $0.kind == .normal }?.handler
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let dismissing = actions.map { action in
            AlertAction(verbatim: action.title, kind: action.kind) { [weak self] in
                self?.answer(action)
            }
        }
        install(AlertPane(content: content, actions: dismissing))
    }

    /// Takes the alert down with no action run, for a task that finished on
    /// its own; `completion` follows once it is gone. One still on its way
    /// in is let arrive first — a dismissal sent mid-presentation is dropped
    /// — and one never presented stays that way (`wantsPresentation`).
    func close(then completion: (() -> Void)? = nil) {
        hasAnswered = true
        if isBeingPresented, let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.close(then: completion)
            }
            return
        }
        guard presentingViewController != nil, !isBeingDismissed else {
            completion?()
            return
        }
        dismiss(animated: true, completion: completion)
    }

    override var wantsPresentation: Bool {
        !hasAnswered
    }

    /// Posted as an alert leaves the screen, answered or not: what a request
    /// waiting for its window to be free (`RelayImport`) listens for.
    static let didDisappear = Notification.Name("wiki.qaq.ighostvt.alertDidDisappear")

    /// Whether `window` shows an alert that is not on its way out — at any
    /// depth, above a sheet or the switcher's cover included.
    static func isShowing(in window: UIWindow) -> Bool {
        var controller = window.rootViewController?.presentedViewController
        while let current = controller {
            if current is AlertViewController, !current.isBeingDismissed {
                return true
            }
            controller = current.presentedViewController
        }
        return false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        if !hasAnswered {
            hasAnswered = true
            onDismissUnanswered?()
        }
        NotificationCenter.default.post(name: Self.didDisappear, object: self)
    }

    private func answer(_ action: AlertAction) {
        guard !hasAnswered else { return }
        hasAnswered = true
        dismiss(animated: true, completion: action.handler)
    }
}

private struct AlertPane: View {
    @ObservedObject var content: AlertViewController.Content
    let actions: [AlertAction]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            AlertCardView(
                title: content.title,
                message: content.message,
                actions: actions,
                progress: content.progress,
            )
            .padding(DS.Padding.l)
        }
    }
}
