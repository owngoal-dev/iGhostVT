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
    /// filled button the card already emphasizes — destructive if any,
    /// otherwise accent.
    var defaultAction: AlertAction? {
        if count == 1 {
            return first
        }
        return last { $0.kind == .destructive }
            ?? last { $0.kind == .accent }
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

    var body: some View {
        VStack(spacing: DS.Padding.l) {
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

            HStack(spacing: DS.Padding.s) {
                ForEach(actions) { action in
                    Button(action: action.handler) {
                        Text(action.title)
                    }
                    .buttonStyle(AlertButtonStyle(kind: action.kind))
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
            if window != nil {
                claimIfNeeded()
            }
        }

        func claimIfNeeded() {
            guard wantsFirstResponder, !isFirstResponder, isInFrontmostPresentation else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, wantsFirstResponder, isInFrontmostPresentation else { return }
                _ = becomeFirstResponder()
            }
        }

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

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if consumeReturn(presses) {
                return
            }
            super.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if isUnmodifiedReturn(presses) {
                return
            }
            super.pressesEnded(presses, with: event)
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
/// 1pt border; the emphasized kinds fill with their tint and speak semibold,
/// the normal one stays clear with accent-colored text. Destructive is the
/// accent treatment in red, standing in for `UIAlertAction`'s `.destructive`.
struct AlertButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case accent
        case destructive
    }

    let kind: Kind

    private var tint: Color {
        kind == .destructive ? .red : .accentColor
    }

    private var isFilled: Bool {
        kind != .normal
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isFilled ? DS.Font.controlEmphasis : DS.Font.body)
            .foregroundColor(isFilled ? .white : .accentColor)
            .padding(DS.Padding.s)
            .frame(maxWidth: .infinity)
            .background(isFilled ? tint : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1),
            )
            // The unfilled kind is text, a 1pt stroke, and clear in between,
            // and clear does not hit-test: without this the button answers
            // only on its letters and its border.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
