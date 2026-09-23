//
//  TerminalTab.swift
//  iGhostVT
//

import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit

/// Which of a tab's two locks is on (`TerminalTab.lock`). They are
/// exclusive: a tab has one lock or none.
enum TabLock: Equatable {
    /// The surface refuses every interaction — touches and keyboard focus.
    case interaction
    /// Only the software keyboard is refused.
    case keyboard

    /// The word every presentation labels this lock with — the badge's
    /// accessibility text, and the overlay capsule's caption.
    var badgeTitle: String {
        switch self {
        case .interaction: String(localized: "Locked")
        case .keyboard: String(localized: "Keyboard Locked")
        }
    }
}

/// One terminal session: its own surface state and its own connection.
/// Tabs stay alive (and connected) while in the background; only the active
/// tab's surface is visible.
///
/// The connection is a daemon session that outlives the app: closing the tab
/// kills the shell (`closeSession`), while scene teardown only detaches
/// (`disconnect`) and the ledger remembers the session ID so a cold launch
/// can reattach.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let terminal: TerminalViewState
    let store: TerminalSessionStore

    /// The tab's lock, if any — one of the two, never both. Either freezes
    /// the *user*, never the program: the session keeps running, output
    /// keeps flowing, and the surface keeps rendering. `interaction` makes
    /// the surface's view refuse touches and keyboard focus
    /// (`LockableTerminalView.isInteractionLocked`); `keyboard` only keeps
    /// the software keyboard down (`isSoftwareKeyboardLocked`) while
    /// touches, scrolling, selection, and hardware keys still work.
    /// The tab's context menu and the main menu are the ways in and out:
    /// choosing the lock that is on removes it, choosing the other one
    /// switches to it.
    @Published var lock: TabLock? {
        didSet {
            guard let view = terminal.attachedPlatformView as? LockableTerminalView else { return }
            view.isInteractionLocked = isLocked
            view.isSoftwareKeyboardLocked = isKeyboardLocked
        }
    }

    /// The interaction lock as a flag — what the presentations badge and
    /// what the menus toggle. Setting it on replaces a keyboard lock;
    /// setting it off clears nothing but itself.
    var isLocked: Bool {
        get { lock == .interaction }
        set { setLock(.interaction, on: newValue) }
    }

    /// The keyboard lock as a flag, with the same exclusive semantics as
    /// `isLocked`.
    var isKeyboardLocked: Bool {
        get { lock == .keyboard }
        set { setLock(.keyboard, on: newValue) }
    }

    private func setLock(_ kind: TabLock, on: Bool) {
        if on {
            lock = kind
        } else if lock == kind {
            lock = nil
        }
    }

    /// The session's process ended — on its own, or because someone asked
    /// it to. Installed by `TabManager.makeTab`, which closes the tab: the
    /// policy lives with the tab list rather than in every tab. Runs after the
    /// store has recorded the exit, so a presenter that reads the status
    /// sees a finished session, never a live one.
    var onSessionExit: (() -> Void)?

    /// Mutable so a reconnect after an in-app detach reattaches to the same
    /// shell instead of spawning a fresh one. Shared with the transport
    /// factory, which reads it at every connect.
    private let daemonSession: DaemonSessionBox
    private var statusObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?
    private var titleObservation: AnyCancellable?
    private var resizeThrottleObservation: AnyCancellable?

    /// The daemon session this tab is attached to, once it has one. Another
    /// tab opened from this one names it so its shell starts in this shell's
    /// current directory.
    var daemonSessionID: UInt64? {
        daemonSession.id
    }

    /// Where this tab's shell is, as the daemon last reported it. `nil`
    /// while the session has not said yet — a tab still connecting, or a
    /// detached one. The new-tab menu lists these; a tab without one simply
    /// offers no row.
    var currentDirectory: TerminalDirectory? {
        store.currentDirectory
    }

    /// `inheritDirectoryFrom` is the daemon session of the tab this one was
    /// opened from; a resumed tab ignores it, since its shell already sits
    /// somewhere. The transport factory sends it on every open, so a shell
    /// that exits and is reopened starts where the *source* shell is by
    /// then — or in the home once that session is gone — never where this
    /// tab's dead shell was.
    ///
    /// `startDirectory` is the same idea for a directory no session can
    /// name any more: a row of the recent list, which is a path the daemon
    /// itself reported.
    init(
        resumeDaemonSessionID: UInt64? = nil,
        inheritDirectoryFrom: UInt64? = nil,
        startDirectory: String? = nil
    ) {
        let daemonSession = DaemonSessionBox(id: resumeDaemonSessionID)
        self.daemonSession = daemonSession
        terminal = TerminalViewState(
            theme: AppTheme.shared.terminalTheme,
            terminalConfiguration: GhosttyAppConfiguration.terminal
        )
        // Built before the store exists (the factory closure cannot capture
        // `self` mid-init), armed right after: the exit the transport
        // observes must reach the store that presents it.
        let exitRelay = ProcessExitRelay()
        store = TerminalSessionStore(makeTransport: {
            let transport = XPCDaemonTransport(
                shellPath: UserDefaults.standard.string(forKey: "Shell.path"),
                resumeSessionID: daemonSession.id,
                inheritDirectoryFrom: inheritDirectoryFrom,
                startDirectory: startDirectory
            )
            // A real process exit (including one we asked for via
            // closeSession) means the ID must never be reused: forget it in
            // the box so the next connect opens a fresh shell instead of
            // attempting a doomed reattach. The daemon's own registry is the
            // only session record; just tell the directory to re-read it.
            transport.onSessionExit = { id, status in
                daemonSession.clear(ifMatches: id)
                exitRelay.fire(status)
                Task { @MainActor in
                    DaemonSessionDirectory.shared.refresh()
                }
            }
            return transport
        })
        exitRelay.handler = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                store.noteProcessExit(status: status)
                onSessionExit?()
            }
        }
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(store.session),
            fontSize: TerminalFontSize.preferred,
            resizeThrottleMilliseconds: Self.resizeThrottle(isShellInForeground: false)
        )
        // The right resize throttle depends on what is drawing: an
        // alt-screen program that repaints on every winsize (vim, Claude
        // Code) needs the stream of sizes bounded or its reflow runs behind
        // the layer for the whole drag, while a shell at its prompt reads
        // the same bound as blinking and is best left unthrottled. Event 102
        // tells the two apart. The switch must be written in two places: a
        // *mounted* surface only hears it through the platform view, whose
        // configuration setter stores straight into the coordinator (its
        // guard skips only the rebuild, and the throttle is read live from
        // the stored options) — the representable's `isEquivalent` check
        // deliberately leaves the throttle out of a surface's identity, so
        // a throttle-only rewrite of `terminal.configuration` never reaches
        // a view that is already up. That rewrite still matters for the
        // view that is not up yet: a freshly made platform view starts from
        // `terminal.configuration`, so keeping it current is what hands a
        // remounted surface the right pace.
        resizeThrottleObservation = Publishers.CombineLatest(
            store.$status.removeDuplicates(),
            store.$isShellInForeground.removeDuplicates()
        )
        .map { status, isShell in
            Self.resizeThrottle(
                isShellInForeground: TerminalSessionStore.isIdleAtPrompt(
                    status: status,
                    isShellInForeground: isShell
                )
            )
        }
        .removeDuplicates()
        .sink { [weak self] milliseconds in
            guard let self else { return }
            terminal.configuration.resizeThrottleMilliseconds = milliseconds
            terminal.attachedPlatformView?.configuration.resizeThrottleMilliseconds = milliseconds
        }
        // The user's arrangement of the keyboard accessory bar; later edits
        // reach existing tabs through RootView's store subscription.
        KeyboardBarStore.shared.apply(to: terminal)
        AppLog.info(
            .tabs,
            "tab \(id) created, resume id \(resumeDaemonSessionID.map(String.init) ?? "none"); waiting for the surface's first viewport"
        )
        // `displayTitle` reads two other observable objects, and SwiftUI
        // only watches the one a view holds — the tab. Without this the
        // title capsule, the tab strip, and the sidebar keep rendering the
        // title the surface had when the view was first built. Published
        // inside an animation so a retitle — which changes a chip's width,
        // and so every chip after it — moves instead of jumping, in every
        // view at once.
        titleObservation = Publishers.Merge3(
            terminal.$title.removeDuplicates().map { _ in () },
            store.$inferredTitle.removeDuplicates().map { _ in () },
            store.$processName.removeDuplicates().map { _ in () }
        )
        .sink { [weak self] in
            withAnimation(DS.Motion.smooth) {
                self?.objectWillChange.send()
            }
        }
        statusObservation = store.$status.sink { [weak self] status in
            guard status == .connected else { return }
            Task { @MainActor [weak self] in
                self?.recordDaemonSessionID()
            }
        }
        // The Live Activity payload carries title, working directory, and
        // connection status; shells retitle and re-report OSC 7 on every
        // prompt, so dedupe each stream and debounce the merge before
        // spending ActivityKit update budget.
        activityObservation = Publishers.Merge4(
            terminal.$title.removeDuplicates().map { _ in () },
            store.$inferredTitle.removeDuplicates().map { _ in () },
            terminal.$workingDirectory.removeDuplicates().map { _ in () },
            store.$status.removeDuplicates().map { _ in () }
        )
        .merge(with: store.$processName.removeDuplicates().map { _ in () })
        .merge(with: store.$currentDirectory.removeDuplicates().map { _ in () })
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { _ in
            Task { @MainActor in
                SessionActivityController.shared.refresh()
            }
        }
        // The app's view subclass carries the interaction-lock policy; the
        // package only provides the seam. Set last, so the closure can read
        // the tab: a view is made whenever the surface mounts — a background
        // tab appearing, SwiftUI rebuilding the representable — and one born
        // after the user locked the tab must come up locked, or the lock
        // lapses the first time the view is rebuilt.
        terminal.makePlatformView = { [weak self] in
            let view = LockableTerminalView(frame: .zero)
            view.isInteractionLocked = self?.isLocked ?? false
            view.isSoftwareKeyboardLocked = self?.isKeyboardLocked ?? false
            return view
        }
    }

    /// What the tab calls itself: what the session says about itself — the
    /// shell-reported title (OSC 2) or the last watched command. Falls back
    /// to the foreground process's name, then the endpoint, for a session
    /// that reports nothing.
    var displayTitle: String {
        if !reportedTitle.isEmpty {
            return reportedTitle
        }
        return store.processName.isEmpty ? store.endpointDescription : store.processName
    }

    /// The line under the title: the foreground process's name ("zsh",
    /// "vim", "grok"), which the daemon reports and which stays short and
    /// stable while programs retitle at will. Never repeats `displayTitle`:
    /// when the process name is already the first line (or there is none),
    /// this is the page's own last non-empty row, so an untitled session
    /// still reads as what it is doing rather than as "zsh" twice.
    var secondaryTitle: String {
        let process = store.processName
        return process.isEmpty || process == displayTitle ? pageFallbackLine : process
    }

    /// The last non-empty row of the viewport, and the endpoint only while
    /// the page is still blank. Computed on render; `store.pageGeneration`
    /// is what re-renders the rows while output flows, so this follows the
    /// page at that pace rather than per chunk.
    private var pageFallbackLine: String {
        _ = store.pageGeneration
        for line in snapshotPreview().split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return store.endpointDescription
    }

    /// The reported title without the endpoint fallback, for the places
    /// that have a better name of their own for a session that never
    /// reported one — the Live Activity, whose widget labels it with the
    /// shell instead. Trailing whitespace is trimmed: programs pad their
    /// OSC 2 titles, and the tab bar would carry the padding.
    var reportedTitle: String {
        let raw = terminal.title.isEmpty ? store.inferredTitle : terminal.title
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether closing this tab would kill a real shell. The box ID is the
    /// authoritative half: a tab detached in the background is not
    /// `.connected`, but its shell is alive in the daemon. A tab that never
    /// got a session has nothing to lose.
    var hasLiveSession: Bool {
        daemonSession.id != nil || store.status == .connected
    }

    /// Milliseconds between grid sizes handed to the surface during a live
    /// resize: none for a shell at its prompt, 128 for a program in front of
    /// it — a step above the library's 96 for full-repaint TUIs, enough for an
    /// A12Z iPad; 200 was tried and taken back as too long a blank strip.
    private static func resizeThrottle(isShellInForeground: Bool) -> Double {
        isShellInForeground ? 0 : 128
    }

    /// Whether closing this tab would interrupt something — the case the
    /// interface confirms first, because `close()` has no undo. A shell
    /// sitting at its prompt is not it: killing an idle shell loses nothing
    /// worth an alert, so the close goes straight through. The trust rule —
    /// only a connected tab can vouch for the foreground, an unknown state
    /// reads as running — lives on the store (`isIdleAtPrompt`), shared
    /// with the resize throttle.
    var hasRunningProgram: Bool {
        guard hasLiveSession else { return false }
        return !store.isIdleAtPrompt
    }

    /// The overlay card (a failed session, or a Mac helper that is not
    /// ready) is covering this tab, so the surface must not hold first
    /// responder — Return and the software keyboard belong to the card.
    var isCoveredByStatusAlert: Bool {
        if !MacLaunchAgent.shared.isReady { return true }
        if case .failed = store.status { return true }
        return false
    }

    /// The surface as last seen — the tab-switcher card's picture. Taken
    /// from the real pixels (`snapshotImage()`), so it is what the user
    /// saw, not a re-typeset: a redraw that happens after the capture (an
    /// appearance toggle over the switcher, output into a hidden tab) is
    /// not in it until the next capture. `nil` for a tab that has never
    /// drawn (a reattached session not yet selected); the card falls back
    /// to `snapshotPreview()` then.
    @Published private(set) var previewImage: UIImage?

    /// Records the surface's current frame as the preview. Only a
    /// rendering surface has one to give: a paused one
    /// (`isSurfaceVisible == false`) may never have presented a frame, and
    /// `snapshotImage()` of that is an empty image, not `nil` — so the
    /// capture happens on the way *out* of visibility (`TabManager`
    /// hides a tab) and when the switcher opens on the visible tab.
    func capturePreview() {
        guard terminal.isSurfaceVisible,
              let image = terminal.attachedPlatformView?.snapshotImage()
        else { return }
        previewImage = image
    }

    /// Viewport text: the page export, and the card preview of a tab that
    /// has no `previewImage` yet.
    func snapshotPreview() -> String {
        store.session.readViewportText() ?? ""
    }

    /// The user closed the tab: the shell dies with it.
    ///
    /// The kill must reach the daemon even when the transport has no live
    /// link (failed connect, detached, daemon restart) — otherwise the
    /// shell runs forever against the daemon's session ceiling with its
    /// ledger entry already gone, so nothing could ever kill it. The
    /// transport, when there is one, knows better than the box which of
    /// those it is in: a transport still in its open or attach round trip
    /// has no id to give yet, but it will — it carries the close out on the
    /// reply, the only way to reach a session the daemon is creating right
    /// now — and one whose connection is gone kills over a side connection
    /// itself. The box is for a tab that never connected at all.
    func close() {
        let transport = store.activeTransport as? XPCDaemonTransport
        if let transport {
            transport.closeSession()
        } else if let id = daemonSession.id {
            XPCDaemonTransport.killSession(id)
        }
        if let id = transport?.currentSessionID ?? daemonSession.id {
            DaemonSessionDirectory.shared.evict(id)
        }
        store.disconnect()
        DaemonSessionDirectory.shared.refresh()
    }

    /// The window is going away but the shell should live on in the daemon;
    /// the ledger already holds the session ID for the next launch.
    func detach() {
        store.disconnect()
    }

    private func recordDaemonSessionID() {
        guard
            let transport = store.activeTransport as? XPCDaemonTransport,
            let id = transport.currentSessionID
        else { return }
        daemonSession.id = id
        DaemonSessionDirectory.shared.refresh()
    }
}

/// Post-init bridge between the transport's exit callback (transport queue,
/// wired inside a factory closure that predates the store) and the store the
/// exit must reach.
final class ProcessExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (Int32) -> Void)?

    var handler: (@Sendable (Int32) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }

    func fire(_ status: Int32) {
        handler?(status)
    }
}

/// Reference cell shared between the tab, its transport factory, and the
/// transport's exit callback (which fires on the transport queue).
final class DaemonSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: UInt64?

    init(id: UInt64?) {
        _id = id
    }

    var id: UInt64? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _id
        }
        set {
            lock.lock()
            _id = newValue
            lock.unlock()
        }
    }

    func clear(ifMatches id: UInt64) {
        lock.lock()
        if _id == id {
            _id = nil
        }
        lock.unlock()
    }
}
