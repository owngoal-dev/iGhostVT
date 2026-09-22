//
//  SessionStatusOverlay.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Covers the terminal while its session is not usable: a quiet pill while
/// the surface starts up or the daemon connection opens, and an alert card
/// once the session ended or the connection failed. Connected shows nothing.
///
/// The card is the shared `AlertCardView` — the same design
/// `AlertViewController` presents — drawn inline over the pane rather than
/// presented, because it must persist while the dead terminal stays on
/// screen. An exited session's card offers Close Tab as the emphasized
/// default — a finished shell is nearly always a finished tab — and Keep Tab
/// as the quieter way to keep the scrollback around and selectable.
///
/// The launch agent is consulted *before* the session, because on a fresh Mac
/// install the session cannot possibly connect: nothing has started the daemon
/// yet. Reading `store.status` first would leave a person watching a
/// "Connecting…" pill that never resolves, when the actual next step is one
/// approval in Login Items.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore
    @ObservedObject private var agent = MacLaunchAgent.shared
    /// Background tabs keep their overlay mounted; only the front tab's
    /// card may steal first responder.
    var isActive: Bool

    /// Closes the tab this session belongs to; provided by the pane's owner.
    var onCloseTab: () -> Void

    /// The failure the user dismissed with Keep Tab. Stored as the dismissed
    /// status so a later, different failure (or a reconnect cycle) presents
    /// its own card again.
    @State private var acknowledged: TerminalSessionStore.Status?

    var body: some View {
        content
            .animation(DS.Motion.smooth, value: store.status)
            .animation(DS.Motion.smooth, value: store.isAwaitingFirstOutput)
            .animation(DS.Motion.smooth, value: agent.status)
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
                    """
                ),
                actions: [AlertAction("Turn On Helper", kind: .accent) { agent.activate() }],
                claimsFirstResponder: isActive
            )
        case .needsApproval:
            AlertCardView(
                title: String(localized: "Allow Terminal Helper"),
                message: String(
                    localized: """
                    iGhostVT needs its background helper before it can open a \
                    terminal. Turn on iGhostVT under Login Items in System \
                    Settings.
                    """
                ),
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Open Login Items", kind: .accent) {
                        agent.openLoginItemsSettings()
                    },
                ],
                claimsFirstResponder: isActive
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
                    """
                ),
                actions: [
                    AlertAction("Quit") { agent.quit() },
                    AlertAction("Download", kind: .accent) {
                        UIApplication.shared.open(MacLaunchAgent.downloadPageURL)
                    },
                ],
                claimsFirstResponder: isActive
            )
        case let .failed(reason):
            AlertCardView(
                title: String(localized: "Terminal Helper Unavailable"),
                message: reason,
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Turn On Helper", kind: .accent) { agent.activate() },
                ],
                claimsFirstResponder: isActive
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
            pill("Connecting…")

        case let .failed(reason):
            if acknowledged != store.status {
                ZStack {
                    dim
                    alertCard(reason: reason)
                        .padding(DS.Padding.l)
                }
                .ignoresSafeArea(.container)
                .transition(.opacity)
            }

        case .connected:
            // The session is open but the shell has yet to print a byte —
            // the first shell after a reboot can take half a minute over
            // its rc files. Without this the pane is an empty terminal
            // that looks exactly like a broken one.
            if store.isAwaitingFirstOutput {
                pill("Starting Shell…")
            }
        }
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

    /// The dim reaches under the bars: they are glass, and a dim that
    /// stops at their edge reads as a second pane.
    private var dim: some View {
        Color.black.opacity(0.25)
            .ignoresSafeArea(.all)
    }

    private var processExited: Bool {
        store.processExitStatus != nil
    }

    private func alertCard(reason: String) -> some View {
        AlertCardView(
            title: processExited
                ? String(localized: "Session Ended")
                : String(localized: "Terminal Unavailable"),
            message: reason,
            actions: processExited
                ? [
                    AlertAction("Keep Tab") {
                        acknowledged = store.status
                    },
                    AlertAction("Close Tab", kind: .accent) {
                        onCloseTab()
                    },
                ]
                : [
                    AlertAction("Close Tab") {
                        onCloseTab()
                    },
                    AlertAction("Retry", kind: .accent) {
                        store.connect()
                    },
                ],
            claimsFirstResponder: isActive
        )
    }
}
