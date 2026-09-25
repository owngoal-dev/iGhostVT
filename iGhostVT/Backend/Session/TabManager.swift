//
//  TabManager.swift
//  iGhostVT
//

import Foundation
import GhosttyTerminal
import SwiftUI

/// The tabs of one window. Owned by that window's `SceneDelegate`; every
/// interface component receives a reference and mutates tabs only through
/// this type.
///
/// Tab insertions and removals are wrapped in `withAnimation` here, so every
/// view of the tab list (panes, strip, sidebar, switcher grid) animates the
/// same change together instead of each view guessing on its own.
@MainActor
final class TabManager: ObservableObject {
    /// One curve for every tab mutation, so a close reads the same in the
    /// strip, the sidebar, and the pane it removes.
    static let tabTransition = DS.Motion.structure
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID? {
        didSet { syncSurfaceVisibility() }
    }

    /// A close awaiting the user's confirmation; presented as one alert by
    /// whichever context owns the screen (see `CloseTabConfirmation`), so
    /// the four close entry points cannot race each other's presentations.
    @Published var closeRequest: TerminalTab?

    /// Clipboard decisions libghostty is waiting on (a program's OSC 52
    /// read or write, a paste that paste protection flagged), answered one
    /// at a time: `ClipboardConfirmation` presents the head the way
    /// `closeRequest` is presented. Every tab's hook is installed by
    /// `makeTab`, so no tab can exist without one and fall back to
    /// libghostty's silent denial.
    @Published private(set) var clipboardRequests: [TerminalClipboardConfirmationRequest] = []

    /// A long press asking for the selection sheet; `RootView` presents it.
    @Published var selectionRequest: TerminalSelectionRequestBox?

    init() {
        SessionActivityController.shared.register(self) { [weak self] in
            self.map {
                SessionActivityController.WindowSnapshot(
                    tabs: $0.tabs,
                    activeTabID: $0.activeTabID,
                )
            }
        }
        // The first window of a cold launch asks the daemon what survived the
        // previous run and reattaches to it; every other window (and a launch
        // with nothing to resume) starts with one fresh tab. The daemon is
        // the only record — nothing about sessions is persisted app-side.
        // A session a tab already holds is skipped: a Shortcut or URL that
        // launched the app opens its tab before the daemon has answered,
        // and that tab has not attached yet, so the answer still lists the
        // session as free.
        DaemonSessionDirectory.shared.claimResumable { [weak self] resumable in
            guard let self else { return }
            let held = Set(tabs.compactMap(\.daemonSessionID))
            let resumable = resumable.filter { !held.contains($0) }
            guard !resumable.isEmpty else {
                if tabs.isEmpty {
                    newTab()
                }
                return
            }
            let resumed = resumable.map { self.makeTab(resume: $0) }
            withAnimation(Self.tabTransition) {
                self.tabs.append(contentsOf: resumed)
                self.activeTabID = self.tabs.last?.id
            }
            if isSceneActive {
                for tab in tabs {
                    tab.store.noteSceneActive()
                }
            }
            SessionActivityController.shared.refresh()
        }
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// The scene these tabs belong to, for a request that has to bring the
    /// window forward (`ShortcutBridge`). Set by the scene delegate.
    weak var windowScene: UIWindowScene?

    func activate(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeTabID = tab.id
    }

    /// A tab for a session the daemon already holds — one a Shortcut or the
    /// CLI opened — attached and brought to the front. The cold-launch
    /// resume batch is the other caller of this shape; the difference is
    /// that this one names the session instead of taking every unattached
    /// one.
    @discardableResult
    func openTab(attachingTo sessionID: UInt64) -> TerminalTab {
        adopt(makeTab(resume: sessionID))
    }

    /// Only the active tab's surface draws. The panes keep every tab mounted
    /// behind an opacity flip, and without this the hidden ones keep a live
    /// display link, rendering frames nobody sees; marking them invisible
    /// keeps grid, scrollback, and session while rendering stops
    /// (`TerminalViewState.isSurfaceVisible`).
    ///
    /// A tab on its way out of view has its preview taken first: once its
    /// surface is paused there is no frame to capture, and the switcher's
    /// card would show nothing.
    private func syncSurfaceVisibility() {
        for tab in tabs {
            let visible = tab.id == activeTabID
            if tab.terminal.isSurfaceVisible != visible {
                if !visible {
                    tab.capturePreview()
                }
                tab.terminal.isSurfaceVisible = visible
                AppLog.verbose(.tabs, "tab \(tab.id) isSurfaceVisible=\(visible)")
            }
        }
    }

    /// Brings the visible tab's preview up to date — the switcher calls it
    /// as it opens, while the panes are still in the window (a full-screen
    /// cover takes them out once its transition completes). The hidden
    /// tabs already hold the frame from when they were last seen.
    func capturePreviews() {
        for tab in tabs {
            tab.capturePreview()
        }
    }

    /// Whether the owning scene has reached foreground-active. Sessions
    /// auto-connect only after it: daemon work stays out of the launch
    /// transition, whose transient layout otherwise sizes the first shell.
    private var isSceneActive = false

    /// Scene-delegate signal; also replayed onto tabs created before the
    /// scene came up (the cold-launch resume batch).
    func noteSceneActive() {
        isSceneActive = true
        AppLog.info(.tabs, "scene active, \(tabs.count) tab(s)")
        for tab in tabs {
            tab.store.noteSceneActive()
        }
    }

    /// Reconnects the tabs that are sitting on a failure.
    ///
    /// `noteSceneActive()` cannot do this: the store's auto-connect fires
    /// exactly once, so a second call is a no-op for a tab that already tried
    /// and failed. On the Mac the first attempt can fail for a reason outside
    /// the app — the background helper was not approved yet — and when that
    /// clears, these tabs deserve the attempt they would have got had the
    /// helper been there at launch.
    func retryFailedTabs() {
        for tab in tabs where tab.store.hasFailed {
            tab.store.connect()
        }
    }

    /// The one way a tab is created: its terminal's hooks land on this
    /// window's presenters before the tab joins `tabs`.
    private func makeTab(
        resume daemonSessionID: UInt64? = nil,
        inheritDirectoryFrom sourceSessionID: UInt64? = nil,
        startDirectory: String? = nil,
    ) -> TerminalTab {
        let tab = TerminalTab(
            resumeDaemonSessionID: daemonSessionID,
            inheritDirectoryFrom: sourceSessionID,
            startDirectory: startDirectory,
        )
        tab.terminal.onClipboardConfirmationRequest = { [weak self] request in
            self?.clipboardRequests.append(request)
        }
        tab.terminal.onTextSelectionRequest = { [weak self] request in
            self?.selectionRequest = TerminalSelectionRequestBox(request: request)
        }
        // A finished shell is a finished tab: close outright — straight to
        // `close`, not `requestClose`: the confirmation guards a running
        // program, and this one is already gone. On a dead session `close` only
        // clears the daemon's record of it.
        tab.onSessionExit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            close(tab)
        }
        return tab
    }

    /// Puts a freshly made tab in front: appended, activated, and — when the
    /// scene is already up — told so, since a tab created after
    /// `noteSceneActive()` gets no replay of it. The cold-launch resume batch
    /// does not go through here: it appends several at once and notifies every
    /// tab, not only the new ones.
    private func adopt(_ tab: TerminalTab) -> TerminalTab {
        withAnimation(Self.tabTransition) {
            tabs.append(tab)
            activeTabID = tab.id
        }
        if isSceneActive {
            tab.store.noteSceneActive()
        }
        SessionActivityController.shared.refresh()
        return tab
    }

    /// The presenter answered the head of `clipboardRequests`.
    func finishClipboardRequest() {
        guard !clipboardRequests.isEmpty else { return }
        clipboardRequests.removeFirst()
    }

    /// Where a new tab's shell starts. The window's own vocabulary for it —
    /// the new-tab menu offers one row per case, and ⌘T is the first.
    enum Origin {
        /// Where the current tab's shell is. A window with no active tab,
        /// or one whose tab has no session yet, gets the home.
        case activeTab
        /// The session user's home: no directory named at all, which is
        /// what the daemon's own plan starts in.
        case home
        /// Wherever this live daemon session's shell is right now — read
        /// from the kernel at the moment the session opens, not whenever
        /// the app last looked.
        case session(UInt64)
        /// A directory the daemon reported earlier, handed straight back.
        /// The recent list is made of these, and they outlive the session
        /// that visited them.
        case directory(TerminalDirectory)
    }

    /// Opens where `origin` says. For a live session the new one names it
    /// and the daemon reads that shell's current directory from the kernel
    /// — so it works for a shell that reports no OSC 7 as well, and no
    /// directory is ever typed into a PTY.
    @discardableResult
    func newTab(_ origin: Origin = .activeTab) -> TerminalTab {
        switch origin {
        case .activeTab:
            adopt(makeTab(inheritDirectoryFrom: activeTab?.daemonSessionID))
        case .home:
            adopt(makeTab())
        case let .session(sessionID):
            adopt(makeTab(inheritDirectoryFrom: sessionID))
        case let .directory(directory):
            adopt(makeTab(startDirectory: directory.path))
        }
    }

    /// Closing the last tab leaves the window empty on purpose: the empty
    /// state offers a fresh terminal, and only a user's tap opens one. The
    /// old auto-replacement spawned its tab from inside the close (sometimes
    /// underneath the tab switcher's full-screen cover, where no surface can
    /// attach), which is exactly the kind of half-mounted terminal that gets
    /// stuck on its connect.
    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        tab.close()
        withAnimation(Self.tabTransition) {
            tabs.remove(at: index)
            if activeTabID == tab.id {
                activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        SessionActivityController.shared.refresh()
    }

    /// The path every close control takes: ask first when a running program
    /// would die with the tab, close straight away when there is nothing to
    /// lose — no session, or a shell idling at its prompt.
    func requestClose(_ tab: TerminalTab) {
        if tab.hasRunningProgram {
            closeRequest = tab
        } else {
            close(tab)
        }
    }

    /// Scene teardown: the window is gone, but its shells belong to the
    /// daemon — detach so they survive for the next launch. Named apart from
    /// `closeAll()` because the difference is the whole point: this one keeps
    /// the shells running, that one kills them. The resume claim goes back
    /// with them: the process may live on with no window, and the next one
    /// to open must find these shells, not start fresh beside them.
    func detachAllTabs() {
        for tab in tabs {
            tab.detach()
        }
        tabs.removeAll()
        activeTabID = nil
        DaemonSessionDirectory.shared.releaseResumableClaim()
        SessionActivityController.shared.refresh()
    }

    /// The user emptied the window from the tab switcher: every shell dies,
    /// exactly as it would from its own ×. Confirmed by the caller.
    func closeAll() {
        for tab in tabs {
            tab.close()
        }
        withAnimation(Self.tabTransition) {
            tabs.removeAll()
            activeTabID = nil
        }
        SessionActivityController.shared.refresh()
    }

    /// Whether closing everything would interrupt a running program — the
    /// case worth a confirmation, mirroring `requestClose(_:)` for a single
    /// tab.
    var hasRunningPrograms: Bool {
        tabs.contains { $0.hasRunningProgram }
    }

    /// A drag in the sidebar or the strip carried `tab` over `destination`:
    /// it takes that slot, and the tabs between shift one place towards
    /// where it came from — the live reorder `TabReorder` drives from
    /// `dropEntered`. The order is the window's alone; ⌘1–9 and ⌃Tab
    /// follow it, the daemon never hears of it.
    func moveTab(_ tab: TerminalTab, toSlotOf destination: TerminalTab) {
        guard
            let from = tabs.firstIndex(where: { $0.id == tab.id }),
            let to = tabs.firstIndex(where: { $0.id == destination.id }),
            from != to
        else { return }
        withAnimation(DS.Motion.smooth) {
            tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func activateAdjacentTab(offset: Int) {
        guard
            let activeTabID,
            let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let next = (index + offset + tabs.count) % tabs.count
        self.activeTabID = tabs[next].id
    }
}

/// Wraps a selection request for SwiftUI's `sheet(item:)`; each long press is
/// its own presentation.
struct TerminalSelectionRequestBox: Identifiable {
    let id = UUID()
    let request: TerminalTextSelectionRequest
}
