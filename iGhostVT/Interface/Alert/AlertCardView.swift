//
//  AlertCardView.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// One action on an alert card. Titles arrive as `String.LocalizationValue`,
/// so a call site's string literal stays a localization key implicitly — the
/// same contract SwiftUI's `.alert` gave those literals via
/// `LocalizedStringKey`. Passing a `String` variable will not compile, which
/// is the point: an unlocalized title has to say so with `verbatim:`.
struct AlertAction: Identifiable {
    let id = UUID()
    let title: String
    let kind: AlertButtonStyle.Kind
    let handler: () -> Void

    init(
        _ title: String.LocalizationValue,
        kind: AlertButtonStyle.Kind = .normal,
        handler: @escaping () -> Void = {},
    ) {
        self.init(verbatim: String(localized: title), kind: kind, handler: handler)
    }

    init(
        verbatim title: String,
        kind: AlertButtonStyle.Kind = .normal,
        handler: @escaping () -> Void = {},
    ) {
        self.title = title
        self.kind = kind
        self.handler = handler
    }
}

extension [AlertAction] {
    /// Return's target: the only action when there is one, otherwise the
    /// highlighted one.
    var defaultAction: AlertAction? {
        if count == 1 {
            return first
        }
        return first { $0.kind == .highlighted }
    }
}

/// The app's one alert design, a SwiftUI rendition of Lakr233/AlertController:
/// centered glass card (material below iOS 26), app-icon header, and a button row whose emphasized
/// action fills with its tint. Shown inline by `SessionStatusOverlay` and
/// presented modally by `AlertViewController` — the design lives here so both
/// stay the same card.
///
/// Title and message are already-resolved strings; localize at the call site
/// (`String(localized:)` or the `AlertAction` initializer above) so literals
/// keep their catalog keys.
struct AlertCardView: View {
    let title: String
    let message: String
    let actions: [AlertAction]
    /// Overlay cards of background tabs stay mounted; only the visible one
    /// may take first responder, or a failed tab in the back would steal
    /// the keyboard from the one in front.
    var claimsFirstResponder = true
    /// A running task's progress, under the message: a spinner until it
    /// knows how far along it is, a bar from then on.
    var progress: AlertProgress?

    var body: some View {
        // Two looks and no more: filled or plain. One highlighted answer at
        // most — Return's — and any other filled one is `.filled`. Three
        // buttons in three colours read as three equally urgent choices.
        assert(actions.filter { $0.kind == .highlighted }.count <= 1, "an alert highlights one action at most")
        return VStack(spacing: DS.Padding.l) {
            Image("AlertIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                // The app icon is the card's decoration; the title says what
                // the alert is about.
                .accessibilityHidden(true)

            Text(title)
                .font(DS.Font.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if !message.isEmpty {
                Text(message)
                    .font(DS.Font.detail)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            }

            switch progress {
            case .indeterminate:
                ProgressView()
            case let .fraction(value):
                ProgressView(value: value)
                    .animation(.easeOut(duration: 0.3), value: value)
            case nil:
                EmptyView()
            }

            // Side by side for two; stacked past that, as the system's
            // alert does, since three do not fit the card's width.
            if actions.count > 2 {
                VStack(spacing: DS.Padding.s) {
                    buttons
                }
            } else {
                HStack(spacing: DS.Padding.s) {
                    buttons
                }
            }
        }
        .padding(DS.Padding.l)
        .frame(maxWidth: 350)
        .cardGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        // The card stands in for `UIAlertController`, inline as well as
        // presented: while it is up it is the whole screen as far as
        // VoiceOver is concerned, and its title, message and buttons are
        // what it contains.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .background {
            if claimsFirstResponder {
                AlertFirstResponder {
                    actions.defaultAction?.handler()
                }
            }
        }
    }
}

enum AlertProgress: Equatable {
    case indeterminate
    case fraction(Double)
}

extension AlertCardView {
    /// A lone button is the answer whatever it says — a progress card's
    /// Cancel included — so it fills; it is Return's target already.
    private var buttons: some View {
        ForEach(actions) { action in
            Button(action: action.handler) {
                Text(action.title)
            }
            .buttonStyle(AlertButtonStyle(kind: actions.count == 1 ? .highlighted : action.kind))
        }
    }
}

/// Becomes first responder for as long as the card is in the window, so the
/// terminal underneath drops the software keyboard (and its accessory bar)
/// and Return reaches the card instead of the shell. The hop matches
/// `TerminalViewState.requestFocus`: becoming first responder writes focus
/// state and must not happen inside a SwiftUI update.
private struct AlertFirstResponder: UIViewRepresentable {
    var onReturn: () -> Void

    func makeUIView(context _: Context) -> ClaimView {
        let view = ClaimView()
        view.onReturn = onReturn
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ClaimView, context _: Context) {
        view.onReturn = onReturn
        view.claimIfNeeded()
    }

    static func dismantleUIView(_ view: ClaimView, coordinator _: ()) {
        view.wantsFirstResponder = false
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    final class ClaimView: UIView {
        var onReturn: () -> Void = {}
        var wantsFirstResponder = true
        private var isHandlingReturn = false

        override var canBecomeFirstResponder: Bool {
            wantsFirstResponder
        }

        override var keyCommands: [UIKeyCommand]? {
            let command = UIKeyCommand(
                input: "\r",
                modifierFlags: [],
                action: #selector(performDefaultAction),
            )
            command.wantsPriorityOverSystemBehavior = true
            return [command]
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
                let center = NotificationCenter.default
                center.removeObserver(self, name: UIWindow.didBecomeKeyNotification, object: nil)
                if let window {
                    center.addObserver(
                        self,
                        selector: #selector(windowDidBecomeKey),
                        name: UIWindow.didBecomeKeyNotification,
                        object: window,
                    )
                }
            #endif
            if window != nil {
                claimIfNeeded()
            }
        }

        func claimIfNeeded() {
            guard wantsFirstResponder, !isFirstResponder, isInFrontmostPresentation, isInKeyWindow else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, wantsFirstResponder, isInFrontmostPresentation, isInKeyWindow else { return }
                _ = becomeFirstResponder()
            }
        }

        /// On the Mac, whether the card's window is the key one. A card in a
        /// window behind — a program there asking for the clipboard, a
        /// session there failing, the helper's card in every window — must
        /// not take the keyboard from the window being typed in, where
        /// Return would then answer it. It claims as its window comes
        /// forward.
        private var isInKeyWindow: Bool {
            #if targetEnvironment(macCatalyst)
                window?.isKeyWindow == true
            #else
                true
            #endif
        }

        #if targetEnvironment(macCatalyst)
            @objc private func windowDidBecomeKey() {
                claimIfNeeded()
            }
        #endif

        /// Whether nothing is presented above this card. An inline card stays
        /// mounted under a modal — the close confirmation its own button
        /// raises, the Mac's settings panel, the iOS settings sheet — and
        /// only the card in the front-most presentation may hold first
        /// responder: two cards reclaiming from each other trade it every
        /// main-queue turn, and one under a panel takes it from the panel's
        /// text field or Escape handler. The walk is `present(in:)`'s, so a
        /// presentation on its way out already counts as gone.
        private var isInFrontmostPresentation: Bool {
            guard let window, var top = window.rootViewController else { return false }
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            guard let topView = top.viewIfLoaded else { return false }
            return isDescendant(of: topView)
        }

        /// `requestFocus` on the terminal hops the same way; if it wins a
        /// round, reclaim on the next turn while the card is still up.
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned, wantsFirstResponder {
                claimIfNeeded()
            }
            return resigned
        }

        // Every other press goes to the application, the end of the
        // responder chain, where the text input system and the menu's key
        // commands take an unhandled press — never `super`: that walks the
        // chain through SwiftUI's key-press responder, whose forward on
        // iPadOS 26.0 lands back on this view's hosting view, and the press
        // circles until the main thread's stack overflows. The terminal's
        // view forwards the same way (libghostty-spm 2.2.2026101002).
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if consumeReturn(presses) {
                return
            }
            UIApplication.shared.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if isUnmodifiedReturn(presses) {
                return
            }
            UIApplication.shared.pressesEnded(presses, with: event)
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            UIApplication.shared.pressesChanged(presses, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            UIApplication.shared.pressesCancelled(presses, with: event)
        }

        @objc private func performDefaultAction() {
            fireReturn()
        }

        private func consumeReturn(_ presses: Set<UIPress>) -> Bool {
            guard isUnmodifiedReturn(presses) else { return false }
            fireReturn()
            return true
        }

        private func isUnmodifiedReturn(_ presses: Set<UIPress>) -> Bool {
            presses.contains { press in
                guard let key = press.key else { return false }
                let extras = key.modifierFlags.subtracting([.numericPad, .alphaShift])
                guard extras.isEmpty else { return false }
                return key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter
            }
        }

        private func fireReturn() {
            guard !isHandlingReturn else { return }
            isHandlingReturn = true
            onReturn()
            DispatchQueue.main.async { [weak self] in
                self?.isHandlingReturn = false
            }
        }
    }
}

/// AlertController's button, translated: full-width rounded rectangle with a
/// 1pt accent border. The highlighted kind fills with the accent and speaks
/// semibold, and so does the filled kind, which only is not Return's
/// default; the normal one stays clear with accent-colored text. There is
/// no third look — a destructive answer is said by its title, not a red
/// fill, so an alert never shows more than these two.
struct AlertButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case highlighted
        /// Looks highlighted but is not the default action: for a second
        /// answer as weighty as the first (a remote tab's detach and
        /// terminate).
        case filled
    }

    let kind: Kind

    private var isFilled: Bool {
        kind != .normal
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isFilled ? DS.Font.controlEmphasis : DS.Font.body)
            .foregroundColor(isFilled ? .white : .accentColor)
            .padding(DS.Padding.s)
            .frame(maxWidth: .infinity)
            .background(isFilled ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1),
            )
            // The unfilled kind is text, a 1pt stroke, and clear in between,
            // and clear does not hit-test: without this the button answers
            // only on its letters and its border.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
