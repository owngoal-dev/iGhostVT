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
    @ViewBuilder var label: () -> Label

    @ObservedObject private var recents = RecentDirectoryStore.shared

    var body: some View {
        // Read once: the same answer decides the shape of this control and
        // fills the menu, and the two must not disagree.
        let choices = NewTabDirectoryChoices(tabManager: tabManager, recents: recents)
        if choices.isEmpty {
            Button {
                tabManager.newTab()
                onOpen()
            } label: {
                label()
            }
            .accessibilityLabel("New Tab")
        } else {
            Menu {
                NewTabMenuContent(tabManager: tabManager, choices: choices, onOpen: onOpen)
            } label: {
                label()
            }
            .accessibilityLabel("New Tab")
        }
    }
}

/// The menu's rows: three inline groups, so every directory is one tap
/// away and nothing hides behind a submenu.
///
/// Home, then where this window's own tabs are, then where sessions have
/// been before. Each group is sorted — the open tabs by path, the recent
/// ones by the order chosen in Settings ▸ Advanced — so a row keeps its
/// place between two openings of the same menu.
struct NewTabMenuContent: View {
    let tabManager: TabManager
    let choices: NewTabDirectoryChoices
    var onOpen: () -> Void = {}

    var body: some View {
        Section {
            // Keyed apart from the keyboard's Home key, which is a
            // different word in half the languages ("Pos1", "Début").
            row(
                String(
                    localized: "Home (directory)",
                    comment: "Menu item: opens a terminal in the home directory; the English text is “Home”"
                ),
                systemImage: "house",
                origin: .home
            )
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
                    row(directory.label, systemImage: "clock", origin: .directory(directory))
                }
            } header: {
                Text("Recent")
            }
        }
    }

    /// A path is not copy: `title` is a string the daemon reported, so it
    /// takes the plain-string label rather than a localizable key.
    private func row(
        _ title: String,
        systemImage: String,
        origin: TabManager.Origin
    ) -> some View {
        Button {
            tabManager.newTab(origin)
            onOpen()
        } label: {
            SwiftUI.Label(title, systemImage: systemImage)
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

        var id: String { directory.path }
    }

    var openTabs: [OpenTab]
    var recents: [TerminalDirectory]

    /// Home is not counted: it is always offered, and a menu that holds
    /// nothing else is not worth opening.
    var isEmpty: Bool {
        openTabs.isEmpty && recents.isEmpty
    }

    @MainActor
    init(tabManager: TabManager, recents store: RecentDirectoryStore) {
        var rows: [OpenTab] = []
        var listed: Set<String> = []
        // The active tab first: when two tabs share a directory, the row
        // should name the session the user is actually looking at.
        let active = tabManager.activeTab
        let ordered = [active].compactMap { $0 } + tabManager.tabs.filter { $0.id != active?.id }
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
