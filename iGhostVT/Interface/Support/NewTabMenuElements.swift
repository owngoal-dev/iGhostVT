//
//  NewTabMenuElements.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// The new-tab menu in UIKit, built at the moment it opens.
///
/// A SwiftUI `Menu` is built from what its view knew at its last render: a
/// paired device's terminals as the last half-minute poll found them, and
/// rows marked open here for tabs closed since. This one lists what is
/// true as it opens: this device's own rows at once, and each paired
/// device's terminals once that device has answered — its submenu shows
/// Loading… until then, or until a short wait runs out. On the Mac a
/// device's terminals are what the catalog holds as the menu opens (see
/// `openTerminals`). The standalone `+`
/// controls (`NewTabMenu`) and the Mac's File ▸ New Tab on Device are built
/// from it; only the ⋯ menu's submenu, a SwiftUI menu inside a SwiftUI
/// menu, still renders from the catalog's last answer.
@MainActor
enum NewTabMenuElements {
    /// How long a device's terminals wait for its answer before the
    /// submenu shows the last list it gave; a device that answers later is
    /// in the next one.
    private static let refreshWait: UInt64 = 1_500_000_000
    /// A device that answered this recently is not asked again: the menu
    /// that has just asked it, opened a second time, uses that answer.
    private static let answerFreshness: TimeInterval = 5

    /// The whole menu for one window, built fresh on every opening.
    static func deferred(tabManager: TabManager, onOpen: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak tabManager] completion in
            // Answered before the provider returns, so the menu opens on
            // its rows with no Loading… of its own.
            MainActor.assumeIsolated {
                askRemoteDevices()
                guard let tabManager else {
                    completion([])
                    return
                }
                completion(elements(tabManager: tabManager, onOpen: onOpen))
            }
        }
    }

    /// Starts asking every paired device for its terminals as a menu
    /// opens, so a device's submenu has the answer by the time the pointer
    /// reaches it. Returns at once.
    ///
    /// Browsing raises the local-network prompt, and on the Mac the menu
    /// bar fills this in as the app launches — so with nothing paired there
    /// is nobody to ask, and no browsing (Settings ▸ Remote Access browses
    /// when someone sets out to pair).
    static func askRemoteDevices() {
        RemoteHostDirectory.shared.startIfPaired()
        let hosts = RemoteHostDirectory.shared.reachablePaired
            .filter { RemoteHostDirectory.shared.mismatchedVersion(of: $0.id) == nil }
        for host in hosts {
            Task { @MainActor in
                await RemoteSessionCatalog.shared.refresh(hostID: host.id, freshness: answerFreshness)
            }
        }
    }

    /// Returns when the device has answered — the ask out now, or one
    /// within `answerFreshness` — or `refreshWait` has passed, whichever is
    /// first. The asking carries on past the wait and lands in the catalog.
    private static func awaitAnswer(fromHostID hostID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task { @MainActor in
                await RemoteSessionCatalog.shared.refresh(hostID: hostID, freshness: answerFreshness)
                gate.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: refreshWait)
                gate.resume()
            }
        }
    }

    /// The rows `NewTabMenuContent` lists, in the same order and groups.
    static func elements(tabManager: TabManager, onOpen: @escaping () -> Void) -> [UIMenuElement] {
        let choices = NewTabDirectoryChoices(
            tabManager: tabManager,
            recents: RecentDirectoryStore.shared,
            remoteHosts: RemoteHostDirectory.shared,
            remoteSessions: RemoteSessionCatalog.shared,
        )
        func row(_ title: String, _ systemImage: String, _ origin: TabManager.Origin) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: systemImage)) { [weak tabManager] _ in
                tabManager?.newTab(origin)
                onOpen()
            }
        }
        var elements: [UIMenuElement] = []
        // This device's own rows. Ghost Remote has none: every row it has
        // is another device's.
        if !AppEdition.isRemoteOnly {
            elements.append(UIMenu(title: "", options: .displayInline, children: [
                row(
                    String(
                        localized: "Home (directory)",
                        comment: "Menu item: opens a terminal in the home directory; the English text is “Home”",
                    ),
                    "house",
                    .home,
                ),
            ]))
        }
        if !choices.openTabs.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "Open Tabs"),
                options: .displayInline,
                children: choices.openTabs.map { row($0.directory.label, "macwindow", .session($0.sessionID)) },
            ))
        }
        if !choices.recents.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "Recent"),
                options: .displayInline,
                children: choices.recents.map { row($0.label, "clock", .directory($0)) },
            ))
        }
        let hosts = remoteHostElements(
            hosts: choices.remoteHosts,
            isOpenHere: { host, session in
                tabManager.tabs.contains { $0.remoteHostID == host.id && $0.remoteSessionID == session.id }
            },
            openFresh: { [weak tabManager] hostID, directory in
                tabManager?.newTab(.remote(hostID: hostID, directory: directory))
                onOpen()
            },
            attach: { [weak tabManager] hostID, sessionID in
                tabManager?.openRemoteTab(attachingTo: sessionID, hostID: hostID)
                onOpen()
            },
        )
        if AppEdition.isRemoteOnly, hosts.count == 1, let host = hosts.first as? UIMenu {
            // Ghost Remote with one device: its rows, not a submenu of one.
            elements.append(UIMenu(title: host.title, options: .displayInline, children: host.children))
        } else if !hosts.isEmpty {
            // "Other" beside this device's rows; Ghost Remote has only
            // other devices.
            let title = AppEdition.isRemoteOnly ? "" : String(localized: "Other Devices")
            elements.append(UIMenu(title: title, options: .displayInline, children: hosts))
        }
        return elements
    }

    /// One submenu per paired device: a fresh shell, its open terminals
    /// (as it answers; on the Mac as last known), and the directories tabs
    /// here were in on it.
    /// Shared with the Mac's File ▸ New Tab on Device.
    static func remoteHostElements(
        hosts: [PairedRemoteHost],
        isOpenHere: @escaping (PairedRemoteHost, XPCDaemonTransport.SessionSummary) -> Bool,
        openFresh: @escaping (String, TerminalDirectory?) -> Void,
        attach: @escaping (String, UInt64) -> Void,
    ) -> [UIMenuElement] {
        hosts.map { host -> UIMenuElement in
            // A device on another iGhostVT cannot be opened: it is listed,
            // greyed, with what to update.
            if let theirs = RemoteHostDirectory.mismatchedVersion(ofHostID: host.id) {
                let action = UIAction(title: host.displayName, image: UIImage(systemName: "network"), attributes: .disabled) { _ in }
                if #available(iOS 16.0, *) {
                    action.subtitle = RemoteVersionText.needsUpdate(theirs: theirs)
                }
                return action
            }
            let fresh = UIAction(
                title: String(localized: "New Terminal", comment: "Menu item: a fresh shell on another device"),
                image: UIImage(systemName: "plus"),
            ) { _ in openFresh(host.id, nil) }
            let recents = RecentDirectoryStore.shared.menuDirectories(onHost: host.id).map { directory in
                UIAction(title: directory.label, image: UIImage(systemName: "clock")) { _ in
                    openFresh(host.id, directory)
                }
            }
            // The same order as this device's own rows: what is open
            // before where one was.
            var children: [UIMenuElement] = [fresh]
            children += openTerminals(of: host, isOpenHere: isOpenHere, attach: attach)
            if !recents.isEmpty {
                children.append(UIMenu(title: String(localized: "Recent"), options: .displayInline, children: recents))
            }
            return UIMenu(title: host.displayName, image: UIImage(systemName: "network"), children: children)
        }
    }

    /// The terminals the device has open, listed once it has answered:
    /// what it holds now, and checkmarks for what is open here now.
    ///
    /// Not on the Mac. AppKit draws every UIKit menu there as an NSMenu,
    /// and a deferred element fulfilled after its NSMenu was rebuilt or
    /// closed crashes the app inside UIKitMacHelper
    /// (`-[UINSMenuController rebuildMenu:]`): in 1.4.1 one device's answer
    /// rebuilt the menu bar (`RemoteSessionCatalog`), and a slower device's
    /// answer, a moment later, landed on the menu that rebuild had thrown
    /// away. So the Mac lists what the catalog holds as the menu opens and
    /// fulfils nothing late; the answer the opening asked for reaches the
    /// menu bar through that rebuild, and a window's menu at its next
    /// opening.
    private static func openTerminals(
        of host: PairedRemoteHost,
        isOpenHere: @escaping (PairedRemoteHost, XPCDaemonTransport.SessionSummary) -> Bool,
        attach: @escaping (String, UInt64) -> Void,
    ) -> [UIMenuElement] {
        #if targetEnvironment(macCatalyst)
            return openTerminalGroup(of: host, isOpenHere: isOpenHere, attach: attach)
        #else
            return [UIDeferredMenuElement.uncached { completion in
                Task { @MainActor in
                    await awaitAnswer(fromHostID: host.id)
                    completion(openTerminalGroup(of: host, isOpenHere: isOpenHere, attach: attach))
                }
            }]
        #endif
    }

    /// Past this many open terminals a device's group leads with Open All.
    static let openAllThreshold = 3

    /// The Open Terminals group as the catalog knows it now, or nothing
    /// when the device holds none. One line per terminal, its title: the
    /// process name under it read as noise in a list of agents that all
    /// run the same binary.
    private static func openTerminalGroup(
        of host: PairedRemoteHost,
        isOpenHere: (PairedRemoteHost, XPCDaemonTransport.SessionSummary) -> Bool,
        attach: @escaping (String, UInt64) -> Void,
    ) -> [UIMenuElement] {
        let sessions = RemoteSessionCatalog.shared.sessions[host.id] ?? []
        guard !sessions.isEmpty else { return [] }
        var open: [UIMenuElement] = sessions.map { session in
            UIAction(
                title: session.menuTitle,
                image: UIImage(systemName: isOpenHere(host, session) ? "checkmark" : "terminal"),
            ) { _ in attach(host.id, session.id) }
        }
        if sessions.count > openAllThreshold {
            let closed = sessions.filter { !isOpenHere(host, $0) }
            open.insert(UIAction(
                title: String(localized: "Open All"),
                image: UIImage(systemName: "square.stack"),
                attributes: closed.isEmpty ? .disabled : [],
            ) { _ in
                for session in closed {
                    attach(host.id, session.id)
                }
            }, at: 0)
        }
        return [UIMenu(title: String(localized: "Open Terminals"), options: .displayInline, children: open)]
    }
}

/// Resumes its continuation the first time it is asked, and never again.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// A transparent button over a SwiftUI label that opens the deferred menu
/// on a tap — what lets `NewTabMenu` keep its label views while the menu
/// itself is UIKit's.
struct NewTabMenuAnchor: UIViewRepresentable {
    let tabManager: TabManager
    let onOpen: () -> Void

    func makeUIView(context _: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "New Tab")
        return button
    }

    func updateUIView(_ button: UIButton, context _: Context) {
        button.menu = UIMenu(children: [NewTabMenuElements.deferred(tabManager: tabManager, onOpen: onOpen)])
    }
}

extension XPCDaemonTransport.SessionSummary {
    /// The first line a menu gives the terminal: the title its tab shows
    /// on the device holding it, word for word — else what is running.
    var menuTitle: String {
        if let title {
            return title
        }
        if let processName, !processName.isEmpty {
            return processName
        }
        return directory?.label ?? String(localized: "Terminal")
    }

}
