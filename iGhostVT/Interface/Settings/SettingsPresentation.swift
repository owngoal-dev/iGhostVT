//
//  SettingsPresentation.swift
//  iGhostVT
//

import SwiftUI
import UIKit

extension View {
    /// Presents `SettingsSheet` the way each platform wants it. iOS gets the
    /// system sheet. The Mac gets `SettingsPanelController`: a Catalyst
    /// sheet flashes the window on its way in and out (the presenter's view
    /// re-lays out under the form sheet's dim), so settings there uses the
    /// alert's presentation instead — a centered card in the system's grouped
    /// background colour over a dimmed pane, cross-dissolved, closed by
    /// Done, Escape, or a click outside.
    func settingsPresentation(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void = {},
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            modifier(SettingsPanelPresenter(isPresented: isPresented, onDismiss: onDismiss))
        #else
            sheet(isPresented: isPresented, onDismiss: onDismiss) {
                SettingsSheet()
            }
        #endif
    }
}

#if targetEnvironment(macCatalyst)

    /// Mirrors `isPresented` onto one `SettingsPanelController` on the
    /// window's front-most context, so the panel lands above the switcher's
    /// cover too. The flag clears when the panel goes, however it went.
    private struct SettingsPanelPresenter: ViewModifier {
        @Binding var isPresented: Bool
        let onDismiss: () -> Void

        @State private var window: UIWindow?
        @State private var presented: SettingsPanelController?

        func body(content: Content) -> some View {
            content
                .background(WindowReader(window: $window))
                .onChange(of: isPresented) { _ in sync() }
                // A request raised before the window was read waits for it.
                .onChange(of: window == nil) { _ in sync() }
        }

        private func sync() {
            if isPresented {
                guard presented == nil, let window else { return }
                let panel = SettingsPanelController {
                    presented = nil
                    isPresented = false
                    onDismiss()
                }
                presented = panel
                panel.present(in: window)
            } else if let panel = presented {
                panel.close()
            }
        }
    }

    /// The settings page as an overlay panel. Owns first responder while it
    /// is up — the terminal underneath would otherwise keep every key,
    /// Escape included — and reports its dismissal once, whoever caused it.
    final class SettingsPanelController: OverlayPanelController {
        private let onDismiss: () -> Void
        private let motion = PanelMotion()
        private var hasReported = false

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
            super.init()
        }

        override func loadView() {
            let view = KeyView()
            view.onEscape = { [weak self] in self?.close() }
            self.view = view
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            Self.stripNavigationBarGlass
            install(SettingsPanel(motion: motion, onClose: { [weak self] in self?.close() }))
        }

        /// Every navigation bar inside the panel — the page and whatever it
        /// pushes — draws nothing: no bar material, no scroll-edge blur, so
        /// the card stays the one flat colour top to bottom.
        private static let stripNavigationBarGlass: Void = {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            let bar = UINavigationBar.appearance(whenContainedInInstancesOf: [SettingsPanelController.self])
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }()

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            view.becomeFirstResponder()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Directly, or with the cover it was presented on: either way
            // the panel is gone and the flag has to follow.
            if isBeingDismissed || presentingViewController == nil {
                report()
            }
        }

        /// The card blurs and shrinks out while the cross-dissolve fades the
        /// pane: the view stays mounted for the length of the dismissal, so
        /// both run together.
        func close() {
            guard !isBeingDismissed else { return }
            withAnimation(DS.Motion.smooth) {
                motion.isShown = false
            }
            dismiss(animated: true)
        }

        private func report() {
            guard !hasReported else { return }
            hasReported = true
            onDismiss()
        }

        /// The panel's root view: first responder for the panel's lifetime,
        /// so hardware keys stop here instead of reaching the terminal, and
        /// Escape closes the panel.
        private final class KeyView: UIView {
            var onEscape: () -> Void = {}

            override var canBecomeFirstResponder: Bool {
                true
            }

            override var keyCommands: [UIKeyCommand]? {
                [UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: [],
                    action: #selector(escape),
                )]
            }

            @objc private func escape() {
                onEscape()
            }
        }
    }

    /// Whether the card is at rest on screen. Off, it sits at 95% under a
    /// blur; the controller flips it on as the pane appears and off again
    /// as it closes, so the card arrives and leaves the same way.
    private final class PanelMotion: ObservableObject {
        @Published var isShown = false
    }

    /// The dimmed pane with the settings card centered on it: a 555-point
    /// square, or the largest square the window holds with its margin — the
    /// card gets smaller, its contents lay out at their real size. The card
    /// is the Form's own list: grouped background behind rows that keep
    /// their own colour. `scrollContentBackground(.hidden)` was tried and
    /// taken back — it clears the *rows* along with the list, which left
    /// the page one flat colour and every row invisible on it. The opaque
    /// grouped background under the Form is what the list's material has
    /// to sample, so a busy terminal no longer bleeds through the page.
    private struct SettingsPanel: View {
        @ObservedObject var motion: PanelMotion
        let onClose: () -> Void

        private let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        private let side: CGFloat = 555

        var body: some View {
            GeometryReader { pane in
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture(perform: onClose)

                    SettingsSheet(onDone: onClose)
                        .frame(width: side(in: pane.size), height: side(in: pane.size))
                        .background(Color(.systemGroupedBackground))
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .scaleEffect(motion.isShown ? 1 : 0.95)
                        .blur(radius: motion.isShown ? 0 : 12)
                        .opacity(motion.isShown ? 1 : 0)
                }
                .frame(width: pane.size.width, height: pane.size.height)
            }
            .onAppear {
                withAnimation(DS.Motion.smooth) {
                    motion.isShown = true
                }
            }
        }

        /// The design size while the pane holds it with its margin; the
        /// largest square that fits otherwise.
        private func side(in pane: CGSize) -> CGFloat {
            let room = min(pane.width, pane.height) - 2 * DS.Padding.xl
            return min(side, max(room, 1))
        }
    }

#endif
