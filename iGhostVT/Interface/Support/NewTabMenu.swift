//
//  NewTabMenu.swift
//  iGhostVT
//

import SwiftUI

/// The new-tab control, wherever one appears — the sidebar's row, the
/// compact bar's `+`, the switcher's dashed card, and the ⋯ menu's own
/// entry. It opens a menu of directories to start the shell in rather than
/// opening a tab outright, because "where" is the only decision a new
/// terminal has.
///
/// With nothing to choose between — a first launch, a window whose tabs have
/// not reported a directory yet — it is the plain button it replaced: a menu
/// of one row would be a tap spent on nothing.
struct NewTabMenu<Label: View>: View {
    @ObservedObject var tabManager: TabManager
    /// Called after a tab is opened, for a presentation that then has to
    /// get out of the way — the tab switcher's full-screen cover.
    var onOpen: () -> Void = {}
    /// The side of the Mac's popover its arrow is on: `.top` hangs it
    /// under the control, `.leading` stands it beside one at the window's
    /// leading edge, where under would run it off the window.
    var popoverArrowEdge: Edge = .top
    @ViewBuilder var label: () -> Label

    @ObservedObject private var recents = RecentDirectoryStore.shared
    @ObservedObject private var remoteHosts = RemoteHostDirectory.shared
    @ObservedObject private var remoteSessions = RemoteSessionCatalog.shared
    #if targetEnvironment(macCatalyst)
        @State private var isShowingPicker = false
    #endif

    var body: some View {
        // Read once: the same answer decides the shape of this control and
        // fills the menu, and the two must not disagree.
        let choices = NewTabDirectoryChoices(
            tabManager: tabManager,
            recents: recents,
            remoteHosts: remoteHosts,
            remoteSessions: remoteSessions,
        )
        if choices.isEmpty {
            Button {
                tabManager.newTab()
                onOpen()
            } label: {
                label()
            }
            .accessibilityLabel("New Tab")
        } else {
            #if targetEnvironment(macCatalyst)
                // The Mac's is a popover (`NewTabPicker`): a dozen paired
                // devices made the menu taller than the window.
                Button {
                    isShowingPicker = true
                } label: {
                    label()
                }
                .accessibilityLabel("New Tab")
                .newTabPicker(
                    isPresented: $isShowingPicker,
                    tabManager: tabManager,
                    arrowEdge: popoverArrowEdge,
                    onOpen: onOpen,
                )
            #else
                // UIKit's menu, built as it opens (`NewTabMenuElements`),
                // over the label; a SwiftUI menu would list what it knew at
                // its last render.
                label()
                    .accessibilityHidden(true)
                    .overlay(NewTabMenuAnchor(tabManager: tabManager, onOpen: onOpen))
            #endif
        }
    }
}

/// New Tab as an entry inside another SwiftUI menu — the ⋯ menu's — where
/// a UIKit button cannot go: the same rows, from the catalog's last answer.
///
/// On iOS the rows are `rows`, taken as a finger comes down on ⋯
/// (`takesNewTabRows`) and left alone until the next touch. UIKit rebuilds
/// an open menu whenever SwiftUI hands it new content, and these rows
/// change on their own: a paired device's terminals carry titles that
/// change with every command (and with every frame of a spinner), and a
/// device on a weak network drops off the relay's list and comes back.
/// Each rebuild closed the New Tab submenu as it opened, so on a phone
/// whose remote tab was busy the submenu would not stay open at all.
///
/// On the Mac the entry is a plain item that opens the popover
/// (`NewTabPicker`) from the menu's own button, which `takesNewTabRows`
/// hangs it on.
struct NewTabSubmenu<Label: View>: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var rows: NewTabMenuRows
    @ViewBuilder var label: () -> Label

    #if targetEnvironment(macCatalyst)
        @ObservedObject private var recents = RecentDirectoryStore.shared
        @ObservedObject private var remoteHosts = RemoteHostDirectory.shared
        @ObservedObject private var remoteSessions = RemoteSessionCatalog.shared
    #endif

    var body: some View {
        #if targetEnvironment(macCatalyst)
            let choices = NewTabDirectoryChoices(
                tabManager: tabManager,
                recents: recents,
                remoteHosts: remoteHosts,
                remoteSessions: remoteSessions,
            )
        #else
            let choices = rows.choices ?? NewTabDirectoryChoices(tabManager: tabManager)
        #endif
        if choices.isEmpty {
            Button(action: { tabManager.newTab() }, label: label)
        } else {
            #if targetEnvironment(macCatalyst)
                Button {
                    // Once the menu has gone: a popover asked for while it
                    // is still closing is dropped.
                    DispatchQueue.main.async { rows.isShowingPicker = true }
                } label: {
                    label()
                }
            #else
                Menu {
                    NewTabMenuContent(tabManager: tabManager, choices: choices)
                } label: {
                    label()
                }
            #endif
        }
    }
}

/// The ⋯ menu's New Tab rows as they were when ⋯ was last touched
/// (`NewTabSubmenu` says why they are not live). One per menu host.
@MainActor
final class NewTabMenuRows: ObservableObject {
    @Published private(set) var choices: NewTabDirectoryChoices?
    #if targetEnvironment(macCatalyst)
        /// The Mac's popover, which the menu's New Tab item opens.
        @Published var isShowingPicker = false
    #endif

    /// Also asks the devices, as the UIKit menu does as it opens: the rows
    /// taken now are what is known, and the answer is in the next touch's.
    func take(from tabManager: TabManager) {
        NewTabMenuElements.askRemoteDevices()
        choices = NewTabDirectoryChoices(tabManager: tabManager)
    }
}

extension View {
    /// Takes the New Tab rows as a finger comes down on this ⋯ menu, before
    /// it opens, once per touch. A menu opened another way — the keyboard,
    /// VoiceOver — shows the rows taken last time.
    func takesNewTabRows(_ rows: NewTabMenuRows, from tabManager: TabManager) -> some View {
        modifier(NewTabRowsTaker(rows: rows, tabManager: tabManager))
    }
}

private struct NewTabRowsTaker: ViewModifier {
    @ObservedObject var rows: NewTabMenuRows
    let tabManager: TabManager
    @State private var isTouching = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
            content.newTabPicker(isPresented: $rows.isShowingPicker, tabManager: tabManager)
        #else
            content.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isTouching else { return }
                        isTouching = true
                        rows.take(from: tabManager)
                    }
                    .onEnded { _ in isTouching = false },
            )
        #endif
    }
}

/// The menu's rows: three inline groups, so every directory is one tap
/// away and nothing hides behind a submenu.
///
/// Home, then where this window's own tabs are, then where sessions have
/// been before. Each group is sorted — the open tabs by path, the recent
/// ones by the order chosen in Settings — so a row keeps its
/// place between two openings of the same menu.
struct NewTabMenuContent: View {
    let tabManager: TabManager
    let choices: NewTabDirectoryChoices
    var onOpen: () -> Void = {}

    var body: some View {
        // Ghost Remote has no home of its own to open in.
        if !AppEdition.isRemoteOnly {
            Section {
                // Keyed apart from the keyboard's Home key, which is a
                // different word in half the languages ("Pos1", "Début").
                row(
                    String(
                        localized: "Home (directory)",
                        comment: "Menu item: opens a terminal in the home directory; the English text is “Home”",
                    ),
                    systemImage: "house",
                    origin: .home,
                )
            }
        }
        if !choices.openTabs.isEmpty {
            Section {
                ForEach(choices.openTabs) { tab in
                    // Named by its session, not its path: the daemon
                    // re-reads the directory as the tab opens, so a shell
                    // that moved in the meantime still opens where it is.
                    row(tab.directory.label, systemImage: "macwindow", origin: .session(tab.sessionID))
                }
            } header: {
                Text("Open Tabs")
            }
        }
        if !choices.recents.isEmpty {
            Section {
                ForEach(choices.recents, id: \.path) { directory in
                    row(directory.name, systemImage: "clock", origin: .directory(directory))
                }
            } header: {
                Text("Recent")
            }
        }
        if !choices.remoteHosts.isEmpty {
            // A submenu each: a device's rows inline made the menu as long
            // as its terminals were many, and read as this device's own.
            Section {
                ForEach(choices.remoteHosts) { host in
                    if let unavailable = unavailableText(host) {
                        // Another iGhostVT there, or out of reach:
                        // listed, greyed, with why.
                        let title = "\(host.displayName) — \(unavailable)"
                        Button {} label: {
                            SwiftUI.Label(title, systemImage: "network")
                        }
                        .disabled(true)
                    } else {
                        Menu {
                            remoteHostRows(host)
                        } label: {
                            SwiftUI.Label(host.displayName, systemImage: "network")
                        }
                    }
                }
            } header: {
                if !AppEdition.isRemoteOnly {
                    Text("Other Devices")
                }
            }
        }
    }

    private func unavailableText(_ host: PairedRemoteHost) -> String? {
        if let theirs = RemoteHostDirectory.mismatchedVersion(ofHostID: host.id) {
            return RemoteVersionText.needsUpdate(theirs: theirs)
        }
        if choices.remoteListings[host.id] == .unreachable {
            return RemoteSessionCatalog.statusText(.unreachable)
        }
        return nil
    }

    /// A paired device: a fresh shell there, one of the terminals it has
    /// open — which then opens here and is taken from where it was — or a
    /// fresh shell in a directory a tab here was in on it.
    @ViewBuilder
    private func remoteHostRows(_ host: PairedRemoteHost) -> some View {
        row(
            String(localized: "New Terminal", comment: "Menu item: a fresh shell on another device"),
            systemImage: "plus",
            origin: .remote(hostID: host.id),
        )
        let recents = choices.remoteRecents[host.id] ?? []
        let listing = choices.remoteListings[host.id] ?? .loading
        let sessions = if case let .listed(rows) = listing { rows } else { [XPCDaemonTransport.SessionSummary]() }
        // Right under New Terminal whenever the device holds a terminal,
        // greyed once every one is open here.
        if !sessions.isEmpty {
            let closed = sessions.filter { !isOpenHere($0, on: host) }
            Button {
                for session in closed {
                    tabManager.openRemoteTab(attachingTo: session.id, hostID: host.id)
                }
                onOpen()
            } label: {
                SwiftUI.Label("Open All", systemImage: "square.stack")
            }
            .disabled(closed.isEmpty)
        }
        if let status = RemoteSessionCatalog.statusText(listing) {
            Section {
                Button {} label: {
                    Text(verbatim: status)
                }
                .disabled(true)
            }
        } else if !sessions.isEmpty {
            Section {
                remoteSessionRows(sessions, on: host)
            } header: {
                Text("Open Terminals")
            }
        }
        if !recents.isEmpty {
            Section {
                remoteRecentRows(recents, on: host)
            } header: {
                Text("Recent")
            }
        }
    }

    private func remoteRecentRows(_ recents: [TerminalDirectory], on host: PairedRemoteHost) -> some View {
        ForEach(recents, id: \.path) { directory in
            row(
                directory.name,
                systemImage: "clock",
                origin: .remote(hostID: host.id, directory: directory),
            )
        }
    }

    private func remoteSessionRows(
        _ sessions: [XPCDaemonTransport.SessionSummary],
        on host: PairedRemoteHost,
    ) -> some View {
        ForEach(sessions) { session in
            Button {
                tabManager.openRemoteTab(attachingTo: session.id, hostID: host.id)
                onOpen()
            } label: {
                SwiftUI.Label {
                    Text(verbatim: session.menuTitle)
                } icon: {
                    Image(systemName: isOpenHere(session, on: host) ? "checkmark" : "terminal")
                }
            }
        }
    }

    private func isOpenHere(_ session: XPCDaemonTransport.SessionSummary, on host: PairedRemoteHost) -> Bool {
        tabManager.tabs.contains { $0.remoteHostID == host.id && $0.remoteSessionID == session.id }
    }

    /// A path is not copy: `title` is a string the daemon reported, so it
    /// takes the plain-string label rather than a localizable key.
    private func row(
        _ title: String,
        systemImage: String,
        origin: TabManager.Origin,
    ) -> some View {
        Button {
            tabManager.newTab(origin)
            onOpen()
        } label: {
            SwiftUI.Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}

/// The directories a new tab could start in, worked out in one place: the
/// control asks whether there are any before deciding to be a menu at all,
/// and the menu then lists exactly these.
struct NewTabDirectoryChoices {
    /// One row per directory the window's tabs are in, deduplicated. Each
    /// carries the session that is there, since a live session knows its
    /// directory better than the app's last report of it.
    struct OpenTab: Identifiable {
        var directory: TerminalDirectory
        var sessionID: UInt64

        var id: String {
            directory.path
        }
    }

    var openTabs: [OpenTab]
    var recents: [TerminalDirectory]
    /// Every paired device (remote access): a fresh shell there, in its
    /// user's home, or a terminal it has open. One not found yet is listed
    /// as connecting, and one nothing can reach greyed — leaving them out
    /// made the menu forget a device for the seconds after launch before
    /// the relay or Bonjour had answered.
    var remoteHosts: [PairedRemoteHost]
    /// What each of those has said about its terminals, as last asked.
    var remoteListings: [String: RemoteSessionCatalog.Listing]
    /// Where tabs here have been on each of those, by host id.
    var remoteRecents: [String: [TerminalDirectory]]

    /// Home is not counted: it is always offered, and a menu that holds
    /// nothing else is not worth opening.
    var isEmpty: Bool {
        openTabs.isEmpty && recents.isEmpty && remoteHosts.isEmpty
    }

    /// From the shared stores, as they are now.
    @MainActor
    init(tabManager: TabManager) {
        self.init(
            tabManager: tabManager,
            recents: .shared,
            remoteHosts: .shared,
            remoteSessions: .shared,
        )
    }

    @MainActor
    init(
        tabManager: TabManager,
        recents store: RecentDirectoryStore,
        remoteHosts: RemoteHostDirectory,
        remoteSessions: RemoteSessionCatalog,
    ) {
        self.remoteHosts = remoteHosts.paired
        remoteListings = Dictionary(uniqueKeysWithValues: self.remoteHosts.map { host in
            (host.id, remoteSessions.listing(of: host.id))
        })
        remoteRecents = Dictionary(uniqueKeysWithValues: self.remoteHosts.map { host in
            (host.id, store.menuDirectories(onHost: host.id))
        })
        var rows: [OpenTab] = []
        var listed: Set<String> = []
        // The active tab first: when two tabs share a directory, the row
        // should name the session the user is actually looking at.
        let active = tabManager.activeTab
        let ordered = [active].compactMap(\.self) + tabManager.tabs.filter { $0.id != active?.id }
        for tab in ordered {
            guard let directory = tab.currentDirectory,
                  let sessionID = tab.daemonSessionID,
                  // Marked as listed either way: a tab sitting in a
                  // directory is reason enough for the recent list not to
                  // offer it as well.
                  listed.insert(directory.path).inserted,
                  // A tab at the home is the row above. Two rows that open
                  // the same shell in the same place is one row too many.
                  !directory.isHome
            else { continue }
            rows.append(OpenTab(directory: directory, sessionID: sessionID))
        }
        openTabs = rows.sorted {
            $0.directory.label.localizedStandardCompare($1.directory.label) == .orderedAscending
        }
        // A directory a tab is already offering is not also a memory of it.
        recents = store.menuDirectories(excluding: listed)
    }
}
