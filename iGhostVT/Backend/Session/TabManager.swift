//
//  TabManager.swift
//  iGhostVT
//

import Combine
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

    /// Where a close came from, for the log line every close writes — so a
    /// tab that vanished can be traced to the control, the key, or the
    /// session end that took it.
    enum TabCloseOrigin: String {
        case keyCommand = "close-tab command"
        case closeButton = "close button"
        case contextMenu = "context menu"
        case statusCard = "status card"
        case confirmation = "confirmed"
        case sessionEnded = "session ended"
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

    private var networkSubscription: AnyCancellable?

    init() {
        networkSubscription = NotificationCenter.default.publisher(for: NetworkPathWatcher.pathDidChange)
            .filter { $0.userInfo?[NetworkPathWatcher.isSatisfiedKey] as? Bool ?? true }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconnectRemoteTabs() }
            }
        SessionActivityController.shared.register(self) { [weak self] in
            self.map {
                SessionActivityController.WindowSnapshot(
                    tabs: $0.tabs,
                    activeTabID: $0.activeTabID,
                )
            }
        }
    }

    /// Fills a new window. A window made for a tab moved out of another one
    /// (`TabWindowMove`) holds that tab and nothing else: it claims none of
    /// the resumable sessions — the moved one is among them as soon as its
    /// old window lets go — and opens no fresh shell beside it.
    ///
    /// Any other window: the first one of a cold launch asks the daemon
    /// what survived the previous run and reattaches to it; every other
    /// window (and a launch with nothing to resume) starts with one fresh
    /// tab. The daemon is the only record — nothing about sessions is
    /// persisted app-side. A session a tab already holds is skipped: a
    /// Shortcut or URL that launched the app opens its tab before the
    /// daemon has answered, and that tab has not attached yet, so the
    /// answer still lists the session as free.
    ///
    /// `isOnlyWindow` is a window the app opened with no other terminal
    /// window up — a launch, or the first window back after the last one
    /// closed. Its fresh tab follows `SessionLaunch`; a window opened beside
    /// another was asked for and always gets one.
    ///
    /// Called by the scene delegate as the window connects, before anything
    /// else can add a tab.
    func populate(movingSession movedSessionID: UInt64?, isOnlyWindow: Bool) {
        if let movedSessionID {
            openTab(attachingTo: movedSessionID)
            return
        }
        let opensFreshTab = !isOnlyWindow || SessionLaunch.opensNewSession
        if AppEdition.isRemoteOnly {
            restoreRemoteTabs(openingFreshTab: opensFreshTab)
        } else {
            resumeLeftovers(openingFreshTab: opensFreshTab)
        }
    }

    /// Ghost Remote's launch: the paired devices' terminals this app had
    /// open when it last went to the background (`RemoteTabLedger`), each
    /// taken back from whoever holds it now, as a terminal picked from the
    /// new-tab menu is. With none, a fresh shell on the preferred device —
    /// or, with no device paired yet, the empty window that says where to
    /// pair one.
    private func restoreRemoteTabs(openingFreshTab: Bool) {
        let (entries, activeIndex) = RemoteTabLedger.claim()
        guard !entries.isEmpty else {
            if openingFreshTab, RemoteTabDefaults.preferredHostID != nil {
                newTab()
            }
            return
        }
        let restored = entries.map { entry in
            let tab = makeTab(resume: entry.sessionID, remoteHostID: entry.hostID)
            tab.store.takesOverOnFirstConnect = true
            return tab
        }
        tabs.append(contentsOf: restored)
        activeTabID = activeIndex.map { restored[$0].id } ?? restored.last?.id
        SessionActivityController.shared.refresh()
    }

    /// Adopts the sessions no peer is attached to — and the ones a paired
    /// device has open, which show here as held there — if this window
    /// wins the claim. `populate` asks as the window connects; the scene asks again
    /// when the Mac's helper comes up, because a claim the daemon could not
    /// answer is left open and the shells it holds are reachable only now.
    func resumeLeftovers(openingFreshTab: Bool = false) {
        DaemonSessionDirectory.shared.claimResumable { [weak self] resumable in
            guard let self else { return }
            // Every window's tabs, not this one's: a session a device holds
            // can already be a tab in another window.
            let held = Set(ShortcutBridge.tabManagers().flatMap(\.tabs).compactMap(\.daemonSessionID))
                .union(tabs.compactMap(\.daemonSessionID))
            let resumable = resumable.filter { !held.contains($0) }
            guard !resumable.isEmpty else {
                if openingFreshTab, tabs.isEmpty {
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

    /// A paired device's terminal, picked from the new-tab menu's list of
    /// them: attached here, taken from wherever it is open — the host's own
    /// window gets it back when this tab lets go. One already open here is
    /// brought to the front instead.
    @discardableResult
    func openRemoteTab(attachingTo sessionID: UInt64, hostID: String) -> TerminalTab {
        for manager in ShortcutBridge.tabManagers() {
            guard let tab = manager.tabs.first(where: { $0.remoteHostID == hostID && $0.remoteSessionID == sessionID })
            else { continue }
            manager.activate(tab)
            if manager !== self, let scene = manager.windowScene {
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
            }
            if tab.store.isHeldElsewhere {
                tab.store.takeOver()
            }
            return tab
        }
        let tab = makeTab(resume: sessionID, remoteHostID: hostID)
        tab.store.takesOverOnFirstConnect = true
        return adopt(tab, afterActiveTab: true)
    }

    /// A terminal a paired device opened on this one (`HostSessionWatcher`):
    /// a tab for it, held there, put at the end without taking the front —
    /// the person here was doing something else.
    func adoptHeldSession(_ sessionID: UInt64) {
        let tab = makeTab(resume: sessionID)
        withAnimation(Self.tabTransition) {
            tabs.append(tab)
            activeTabID = activeTabID ?? tab.id
        }
        if isSceneActive {
            tab.store.noteSceneActive()
        }
        SessionActivityController.shared.refresh()
    }

    /// The device holding `sessionID` let go of it: the tab showing it as
    /// held there takes it back.
    func reattachReleased(_ sessionID: UInt64) {
        for tab in tabs where tab.daemonSessionID == sessionID && tab.store.isHeldElsewhere {
            tab.store.connect()
        }
    }

    /// `sessionID` ended while no tab here was attached to hear it — a
    /// device held it, or its tab has not connected yet: that tab goes the
    /// way an ended session's does, rather than reaching a gone session and
    /// opening a fresh shell in its place.
    func closeEnded(_ sessionID: UInt64) {
        for tab in tabs where tab.daemonSessionID == sessionID && tab.store.status != .connected {
            close(tab, from: .sessionEnded)
        }
    }

    /// A remote tab let go of here, its shell left running on its host —
    /// whose own window takes it back. The other half of a remote tab's
    /// close; the confirmation offers both.
    func detach(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        AppLog.info(.tabs, "detaching tab \(tab.id), session \(Self.describeSession(of: tab))")
        tab.detach()
        remove(at: index)
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
            tab.store.isFrontTab = visible
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
        for tab in tabs {
            if tab.store.hasFailed {
                tab.store.connect()
            } else {
                // A remote tab backing off after its link died while the
                // app was away: now is the moment to try.
                tab.store.reconnectNowIfWaiting()
            }
        }
    }

    /// The app came back to the foreground: each tab takes its session
    /// back, once, the first time it is in front
    /// (`TerminalSessionStore.armForegroundTakeover`).
    func armForegroundTakeover() {
        for tab in tabs {
            tab.store.armForegroundTakeover()
        }
    }

    /// Every remote tab whose link is down tries again now
    /// (`TerminalSessionStore.reconnectNow`): the network came back or
    /// moved, or the app came forward.
    func reconnectRemoteTabs() {
        for tab in tabs {
            tab.store.reconnectNow()
        }
    }

    /// The one way a tab is created: its terminal's hooks land on this
    /// window's presenters before the tab joins `tabs`.
    private func makeTab(
        resume daemonSessionID: UInt64? = nil,
        inheritDirectoryFrom sourceSessionID: UInt64? = nil,
        startDirectory: String? = nil,
        remoteHostID: String? = nil,
    ) -> TerminalTab {
        let tab = TerminalTab(
            resumeDaemonSessionID: daemonSessionID,
            inheritDirectoryFrom: sourceSessionID,
            startDirectory: startDirectory,
            remoteHostID: remoteHostID,
        )
        if let remoteHostID {
            RemoteTabDefaults.noteOpened(onHostID: remoteHostID)
        }
        tab.terminal.onClipboardConfirmationRequest = { [weak self] request in
            self?.clipboardRequests.append(request)
        }
        // A finished shell is a finished tab: close outright — straight to
        // `close`, not `requestClose`: the confirmation guards a running
        // program, and this one is already gone. On a dead session `close` only
        // clears the daemon's record of it.
        tab.onSessionExit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            close(tab, from: .sessionEnded)
        }
        return tab
    }

    /// Puts a freshly made tab in front: placed, activated, and — when the
    /// scene is already up — told so, since a tab created after
    /// `noteSceneActive()` gets no replay of it. A tab the user opens goes
    /// right after the one they were in, as a browser's does, so it lands
    /// beside the work it came from instead of past every other tab; one
    /// that arrives from outside (a Shortcut, a URL, a moved session) is
    /// appended. The cold-launch resume batch does not go through here: it
    /// appends several at once and notifies every tab, not only the new ones.
    private func adopt(_ tab: TerminalTab, afterActiveTab: Bool = false) -> TerminalTab {
        withAnimation(Self.tabTransition) {
            if afterActiveTab, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs.insert(tab, at: index + 1)
            } else {
                tabs.append(tab)
            }
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
        /// A paired device's daemon (remote access): a fresh shell there,
        /// in its user's home or in `directory` — one that device reported
        /// earlier, handed back to it.
        case remote(hostID: String, directory: TerminalDirectory? = nil)

        var isRemote: Bool {
            if case .remote = self {
                return true
            }
            return false
        }
    }

    /// The window these tabs are in, for what a tab action has to present.
    private var terminalWindow: TerminalWindow? {
        windowScene?.windows.lazy.compactMap { $0 as? TerminalWindow }.first
    }

    /// Opens where `origin` says. For a live session the new one names it
    /// and the daemon reads that shell's current directory from the kernel
    /// — so it works for a shell that reports no OSC 7 as well, and no
    /// directory is ever typed into a PTY.
    ///
    /// Ghost Remote has no shell of its own: an origin on this device opens
    /// on the active tab's device, else the preferred paired one, and with
    /// no device paired it opens Settings ▸ Remote Access and no tab.
    @discardableResult
    func newTab(_ origin: Origin = .activeTab) -> TerminalTab? {
        if AppEdition.isRemoteOnly, !origin.isRemote {
            guard let hostID = activeTab?.remoteHostID ?? RemoteTabDefaults.preferredHostID else {
                terminalWindow?.interface.showRemoteAccess()
                return nil
            }
            return adopt(makeTab(remoteHostID: hostID), afterActiveTab: true)
        }
        let tab = switch origin {
        case .activeTab:
            // From a remote tab, ⌘T opens another shell on that device.
            if let hostID = activeTab?.remoteHostID {
                makeTab(remoteHostID: hostID)
            } else {
                makeTab(inheritDirectoryFrom: activeTab?.daemonSessionID)
            }
        case .home:
            makeTab()
        case let .session(sessionID):
            makeTab(inheritDirectoryFrom: sessionID)
        case let .directory(directory):
            makeTab(startDirectory: directory.path)
        case let .remote(hostID, directory):
            makeTab(startDirectory: directory?.path, remoteHostID: hostID)
        }
        return adopt(tab, afterActiveTab: true)
    }

    /// Closing the last tab leaves the window empty on purpose: the empty
    /// state offers a fresh terminal, and only a user's tap opens one. The
    /// old auto-replacement spawned its tab from inside the close (sometimes
    /// underneath the tab switcher's full-screen cover, where no surface can
    /// attach), which is exactly the kind of half-mounted terminal that gets
    /// stuck on its connect.
    func close(_ tab: TerminalTab, from origin: TabCloseOrigin) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        AppLog.info(.tabs, "closing tab \(tab.id) (\(origin.rawValue)), session \(Self.describeSession(of: tab))")
        tab.close()
        remove(at: index)
    }

    /// The tab is moving to another window (`TabWindowMove`): it leaves this
    /// one detached, never closed — the shell is the one the other window
    /// is about to attach to, and that attach waits out this detach.
    func handOff(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        AppLog.info(.tabs, "tab \(tab.id) moves to another window, session \(Self.describeSession(of: tab))")
        tab.detach()
        remove(at: index)
    }

    /// Takes the tab at `index` out of the list, handing the selection to
    /// its neighbour when it was the active one.
    private func remove(at index: Int) {
        let id = tabs[index].id
        withAnimation(Self.tabTransition) {
            tabs.remove(at: index)
            if activeTabID == id {
                activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        SessionActivityController.shared.refresh()
    }

    /// The path every close control takes: ask first when a running program
    /// would die with the tab, close straight away when there is nothing to
    /// lose — no session, or a shell idling at its prompt.
    func requestClose(_ tab: TerminalTab, from origin: TabCloseOrigin) {
        // A remote tab another device is using has nothing to end from
        // here: it lets go and the shell keeps running, without a question.
        // (A local tab held elsewhere still asks — detached, it would come
        // straight back as a held tab, `HostSessionWatcher`.)
        if tab.isRemote, tab.store.isHeldElsewhere {
            AppLog.info(.tabs, "close of tab \(tab.id) (\(origin.rawValue)) held elsewhere: detaching")
            detach(tab)
            return
        }
        // A remote tab otherwise asks: leave the shell running on its host,
        // or end it.
        if tab.hasRunningProgram || tab.isRemote {
            AppLog.info(.tabs, "close of tab \(tab.id) (\(origin.rawValue)) awaits confirmation, session \(Self.describeSession(of: tab))")
            closeRequest = tab
        } else {
            close(tab, from: origin)
        }
    }

    /// The daemon session a log line about `tab` names: the one id a "my
    /// tabs closed by themselves" report can be matched against the
    /// daemon's own log with.
    private static func describeSession(of tab: TerminalTab) -> String {
        if let remoteHostID = tab.remoteHostID {
            return "remote \(remoteHostID)#\(tab.remoteSessionID.map(String.init) ?? "none")"
        }
        return tab.daemonSessionID.map(String.init) ?? "none"
    }

    /// Scene teardown: the window is gone, but its shells belong to the
    /// daemon — detach so they survive for the next launch. Named apart from
    /// `closeAll()` because the difference is the whole point: this one keeps
    /// the shells running, that one kills them. Its remote tabs let go of
    /// their ledger entries as they detach, so the next window to open
    /// reopens them.
    func detachAllTabs() {
        AppLog.info(.tabs, "scene gone, detaching \(tabs.count) tab(s), sessions \(tabs.map(Self.describeSession(of:)))")
        for tab in tabs {
            tab.detach()
        }
        tabs.removeAll()
        activeTabID = nil
        DaemonSessionDirectory.shared.releaseResumableClaim()
        SessionActivityController.shared.refresh()
    }

    /// The user emptied the window from the tab switcher: every shell dies,
    /// exactly as it would from its own ×. Confirmed by the caller. A
    /// remote tab is only let go of — its shell is its host's, and ending
    /// one is asked one tab at a time.
    func closeAll() {
        AppLog.info(.tabs, "closing all \(tabs.count) tab(s), sessions \(tabs.map(Self.describeSession(of:)))")
        for tab in tabs {
            if tab.isRemote {
                tab.detach()
            } else {
                tab.close()
            }
        }
        withAnimation(Self.tabTransition) {
            tabs.removeAll()
            activeTabID = nil
        }
        SessionActivityController.shared.refresh()
    }

    /// Whether closing everything would interrupt a running program — the
    /// case worth a confirmation, mirroring `requestClose(_:from:)` for a single
    /// tab. A remote tab interrupts nothing: `closeAll` only lets go of it.
    var hasRunningPrograms: Bool {
        tabs.contains { !$0.isRemote && $0.hasRunningProgram }
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
