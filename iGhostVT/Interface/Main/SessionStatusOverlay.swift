//
//  SessionStatusOverlay.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Covers the terminal while its session is not usable: a quiet pill while
/// the surface starts up or the daemon connection opens, and an alert card
/// once the session ended or the connection failed. Connected shows nothing
/// but a short notice when a paste was cut short.
///
/// The card is the shared `AlertCardView` — the same design
/// `AlertViewController` presents — drawn inline over the pane rather than
/// presented, because it must persist while the dead terminal stays on
/// screen. A session whose shell exited gets no card: its tab closes on its
/// own (`TabManager`), and the disconnect that follows the exit lands while
/// the pane is already animating out — a card shown then only flashed over
/// a tab on its way out.
///
/// The launch agent is consulted *before* the session, because on a fresh Mac
/// install the session cannot possibly connect: nothing has started the daemon
/// yet. Reading `store.status` first would leave a person watching a
/// "Connecting…" pill that never resolves, when the actual next step is one
/// approval in Login Items.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore
    @ObservedObject private var agent = MacLaunchAgent.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Background tabs keep their overlay mounted; only the front tab's
    /// card may steal first responder.
    var isActive: Bool
    /// The tab's close alert is up: the failure card is taken down while it
    /// is, since alerts never stack, and comes back if the close is cancelled.
    var isAwaitingClose = false

    /// Closes the tab this session belongs to; provided by the pane's owner.
    var onCloseTab: () -> Void

    var body: some View {
        content
            .animation(DS.Motion.smooth, value: store.status)
            .animation(DS.Motion.smooth, value: store.isAwaitingFirstOutput)
            .animation(DS.Motion.smooth, value: store.isPasteTruncated)
            .animation(DS.Motion.smooth, value: store.zmodemTransfer)
            .animation(DS.Motion.smooth, value: agent.status)
            .animation(DS.Motion.smooth, value: isAwaitingClose)
    }

    @ViewBuilder
    private var content: some View {
        if agent.isReady {
            sessionContent
        } else if agent.status == .rebinding {
            // An update replaced the helper and its registration is being
            // redone — seconds, and nothing for a person to do. The
            // connection comes on its own when the status turns enabled.
            pill("Updating Terminal Helper…")
        } else {
            ZStack {
                dim
                agentCard
                    .padding(DS.Padding.l)
            }
            // Under the bars too: they are glass, and a dim that stops at
            // their edge reads as a second pane.
            .ignoresSafeArea(.container)
            .transition(.opacity)
        }
    }

    /// The one thing standing between a fresh install and a terminal, said
    /// plainly. Every state names its own next step, and none of them is
    /// "retry the connection" — the connection is not what is missing.
    @ViewBuilder
    private var agentCard: some View {
        switch agent.status {
        case .needsRelocation:
            // The window's `relocationPrompt` alert is the whole story here,
            // and it sits over this dim; a card under it would only stack.
            EmptyView()
        case .notRegistered:
            AlertCardView(
                title: String(localized: "Turn On Terminal Helper"),
                message: String(
                    localized: """
                    The background helper that runs your terminals is switched \
                    off. Turn it back on to open a terminal.
                    """,
                ),
                actions: [AlertAction("Turn On Helper", kind: .highlighted) { agent.activate() }],
                claimsFirstResponder: isActive,
            )
        case .needsApproval:
            AlertCardView(
                title: String(localized: "Allow Terminal Helper"),
                message: String(
                    localized: """
                    iGhostVT needs its background helper before it can open a \
                    terminal. Turn on iGhostVT under Login Items in System \
                    Settings.
                    """,
                ),
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Open Login Items", kind: .highlighted) {
                        agent.openLoginItemsSettings()
                    },
                ],
                claimsFirstResponder: isActive,
            )
        case .brokenInstallation:
            // Nothing in the app can repair a bundle with pieces missing, so
            // the card opens the page a whole one comes from — a URL in the
            // text could not be clicked — and offers the way out.
            AlertCardView(
                title: String(localized: "Broken Installation"),
                message: String(
                    localized: """
                    Part of iGhostVT is missing, so it cannot open a terminal. \
                    Download iGhostVT again and replace this copy.
                    """,
                ),
                actions: [
                    AlertAction("Quit") { agent.quit() },
                    AlertAction("Download", kind: .highlighted) {
                        UIApplication.shared.open(MacLaunchAgent.downloadPageURL)
                    },
                ],
                claimsFirstResponder: isActive,
            )
        case let .failed(reason):
            AlertCardView(
                title: String(localized: "Terminal Helper Unavailable"),
                message: reason,
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Turn On Helper", kind: .highlighted) { agent.activate() },
                ],
                claimsFirstResponder: isActive,
            )
        case .notApplicable, .unsupported, .rebinding, .enabled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch store.status {
        case .idle:
            // Idle means the surface hasn't reported its grid yet — normally
            // milliseconds, but if it sticks the pill is the only sign the
            // window isn't just an empty terminal.
            pill("Starting…")

        case .connecting:
            // A file dropped meanwhile waits for the connection; its pill
            // is up already, so it can be cancelled from here.
            ZStack {
                pill("Connecting…")
                if let transfer = store.zmodemTransfer {
                    transferPill(transfer)
                }
            }

        case let .failed(reason):
            if store.processExitStatus == nil, !isAwaitingClose {
                ZStack {
                    dim
                    alertCard(reason: reason)
                        .padding(DS.Padding.l)
                }
                .ignoresSafeArea(.container)
                .transition(.opacity)
            }

        case let .elsewhere(holder):
            if !isAwaitingClose {
                ZStack {
                    dim
                    elsewhereCard(holder: holder)
                        .padding(DS.Padding.l)
                }
                .ignoresSafeArea(.container)
                .transition(.opacity)
            }

        case .connected:
            if let transfer = store.zmodemTransfer {
                transferPill(transfer)
            } else if store.isAwaitingFirstOutput {
                // The session is open but the shell has yet to print a byte —
                // the first shell after a reboot can take half a minute over
                // its rc files. Without this the pane is an empty terminal
                // that looks exactly like a broken one.
                pill("Starting Shell…")
            } else if store.isPasteTruncated {
                notice("Paste truncated: the program is not reading its input.")
            }
        }
    }

    /// The phone's layout, with the tab bar along the bottom. Never on the
    /// Mac, whose narrow window still has the sidebar's layout.
    private var isCompactWidth: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            horizontalSizeClass == .compact
        #endif
    }

    /// The pane ends above the keyboard and its accessory bar (nothing here
    /// ignores the keyboard's safe area), so either place clears them. Over
    /// a bottom bar — a phone, a narrow iPad window — the transfer sits
    /// centred just above it, the way a toast does, and grows into place;
    /// beside a sidebar, shown or collapsed, it keeps to the corner.
    private func transferPill(_ transfer: ZmodemTransferInfo) -> some View {
        ZmodemTransferPill(info: transfer) { store.cancelZmodemTransfer() }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: isCompactWidth ? .bottom : .bottomTrailing,
            )
            .padding(DS.Padding.l)
            .transition(isCompactWidth ? .scale(scale: 0.85).combined(with: .opacity) : .opacity)
    }

    private func pill(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: DS.Padding.s) {
            ProgressView()
                .accessibilityHidden(true)
            Text(title)
                .font(DS.Font.labelEmphasis)
        }
        .padding(.horizontal, DS.Padding.l)
        .padding(.vertical, DS.Padding.m)
        .barGlass(in: Capsule(), interactive: false)
        // One status element: the spinner adds nothing the phase does not
        // already say, and the phase moves on by itself.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.opacity)
    }

    /// A pill without the spinner: something that already happened, said
    /// once and gone on its own.
    private func notice(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Font.labelEmphasis)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Padding.l)
            .padding(.vertical, DS.Padding.m)
            .barGlass(in: Capsule(), interactive: false)
            .padding(.horizontal, DS.Padding.l)
            .transition(.opacity)
    }

    /// The dim reaches under the bars: they are glass, and a dim that
    /// stops at their edge reads as a second pane.
    private var dim: some View {
        Color.black.opacity(0.25)
            .ignoresSafeArea(.all)
    }

    /// The session is open somewhere else — a device took it, or this tab
    /// came back to find one holding it. Nothing failed: Use Here takes it
    /// back, and the other side is told.
    private func elsewhereCard(holder: String?) -> some View {
        AlertCardView(
            title: holder.map {
                String.localizedStringWithFormat(
                    NSLocalizedString("In Use on “%@”", comment: "A terminal in use on another device; %@ is that device"),
                    $0,
                )
            } ?? String(localized: "In Use in Another Window"),
            message: holder == nil
                ? String(localized: "Use Here moves it to this window.")
                : String(localized: "Use Here moves it to this device."),
            actions: [
                AlertAction("Close Tab") {
                    onCloseTab()
                },
                AlertAction("Use Here", kind: .highlighted) {
                    store.takeOver()
                },
            ],
            claimsFirstResponder: isActive,
        )
    }

    private func alertCard(reason: String) -> some View {
        AlertCardView(
            title: String(localized: "Terminal Unavailable"),
            message: reason,
            actions: [
                AlertAction("Close Tab") {
                    onCloseTab()
                },
                AlertAction("Retry", kind: .highlighted) {
                    store.connect()
                },
            ],
            claimsFirstResponder: isActive,
        )
    }
}
