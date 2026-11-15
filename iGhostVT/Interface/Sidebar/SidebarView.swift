import Combine
import SwiftUI

/// Safari-iPad-style sidebar listing tabs for regular width. Selection,
/// close, and new-tab all route through the same `TabManager` the tab strip
/// and switcher use.
struct SidebarView: View {
    @ObservedObject var tabManager: TabManager
    /// The sidebar carries its own toggle while open, at the trailing end
    /// of its top strip — beside the separator it closes.
    @Binding var showsSidebar: Bool
    let onShowSettings: () -> Void
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: UIWindow?
    @StateObject private var reorderPacing = TabReorderPacing()
    @Environment(\.windowControlsLeading) private var windowControlsLeading
    /// The folded device groups' keys, one per line; remembered like the
    /// sidebar's visibility and width.
    @AppStorage("Sidebar.collapsedDevices") private var collapsedStorage = ""
    @AppStorage(TabGrouping.key) private var groupsByDevice = false

    var body: some View {
        VStack(spacing: 0) {
            // On iPad the sidebar's head is the one place the product name
            // shows. The Mac's title bar is hidden, and its strip — where
            // the traffic lights float — is kept clear and drags the window.
            #if targetEnvironment(macCatalyst)
                WindowDragRegion()
                    .frame(height: CatalystWindowChrome.titleBarHeight)
                    .overlay(alignment: .trailing) {
                        toggle
                            .padding(.horizontal, DS.Padding.s)
                    }
            #else
                header
                    .padding(.leading, windowControlsLeading)
            #endif

            ScrollView {
                let groups = (TabGrouping.isAvailable && groupsByDevice)
                    ? TabGrouping.groups(tabManager.tabs, hostID: \.remoteHostID)
                    : [TabGrouping.Group(hostID: nil, items: tabManager.tabs)]
                let showsHeaders = groups.count > 1
                // Not lazy: a window has tens of tabs at most, nothing here
                // is worth deferring, and a plain stack keeps every row's
                // drag and drop hooks mounted while a reorder moves them.
                VStack(spacing: 2) {
                    ForEach(groups, id: \.key) { group in
                        let isCollapsed = showsHeaders && collapsedGroups.contains(group.key)
                        if showsHeaders {
                            SidebarGroupHeader(
                                tabManager: tabManager,
                                hostID: group.hostID,
                                tabs: group.items,
                                isCollapsed: isCollapsed,
                                holdsActiveTab: group.items.contains { $0.id == tabManager.activeTabID },
                                onToggle: { toggleCollapse(group.key) },
                                onOpen: { expand(group.key) },
                            )
                            .padding(.top, group.key == groups.first?.key ? 0 : DS.Padding.s)
                        }
                        if !isCollapsed {
                            ForEach(group.items) { tab in
                                SidebarRow(
                                    tab: tab,
                                    isActive: tab.id == tabManager.activeTabID,
                                    showsDevice: !showsHeaders,
                                    onSelect: { tabManager.activeTabID = tab.id },
                                    onClose: { tabManager.requestClose(tab, from: .closeButton) },
                                )
                                .onMiddleClick { tabManager.requestClose(tab, from: .middleClick) }
                                .tabMenuAndReorder(tab, in: tabManager, pacing: reorderPacing, preview: .row, window: window)
                            }
                        }
                    }

                    NewTabMenu(tabManager: tabManager, popoverArrowEdge: .leading) {
                        HStack(spacing: DS.Padding.s) {
                            Image(systemName: "plus")
                                .font(DS.Font.labelEmphasis)
                                .frame(width: 16)
                            Text("New Tab")
                                .font(DS.Font.label)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, DS.Padding.m)
                        .padding(.vertical, DS.Padding.m)
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(DS.Padding.m)
                .frame(maxWidth: .infinity)
                .tabReorderContainer()
                // On the container, keyed on the value: a write to
                // `@AppStorage` does not land inside a `withAnimation`.
                .animation(DS.Motion.smooth, value: collapsedStorage)
            }

            footer
        }
        // The sidebar paints no background of its own: it is the terminal's
        // own background colour, painted once by `RootView` under the whole
        // window, so the two columns read as one surface. (A material here
        // tinted the theme's colour into something neither column had.)
        // For the context menu's share sheet, which presents via UIKit.
        .background(WindowReader(window: $window))
        .overlay(alignment: .trailing) {
            // Half the hairline the cards and switcher use: this one runs
            // the window's full height, and at full strength it reads as a
            // border rather than a seam.
            Rectangle()
                .fill(theme.hairline(for: colorScheme).opacity(0.5))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    /// The folded groups' keys (`TabGrouping.Group.key`).
    private var collapsedGroups: Set<String> {
        Set(collapsedStorage.split(separator: "\n").map(String.init))
    }

    private func toggleCollapse(_ key: String) {
        var groups = collapsedGroups
        if groups.remove(key) == nil {
            groups.insert(key)
        }
        collapsedStorage = groups.sorted().joined(separator: "\n")
    }

    /// A terminal opened from a folded group's `+` shows up in it.
    private func expand(_ key: String) {
        var groups = collapsedGroups
        guard groups.remove(key) != nil else { return }
        collapsedStorage = groups.sorted().joined(separator: "\n")
    }

    /// The top bar's height, so the list starts level with the terminal
    /// under the bar and the toggle sits at the bar's own inset from the
    /// window's top, as it does in the bar.
    private var header: some View {
        HStack(spacing: DS.Padding.s) {
            Text(verbatim: AppEdition.displayName)
                .font(DS.Font.title)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, DS.Padding.s)
            Spacer()
            toggle
        }
        .padding(.horizontal, DS.Padding.s)
        .padding(.vertical, DS.Padding.s)
        .frame(maxWidth: .infinity)
    }

    /// Styled like the footer's gear: the sidebar's controls are quiet,
    /// the glass disc belongs to the bar.
    private var toggle: some View {
        SidebarToggleButton(showsSidebar: $showsSidebar)
            .foregroundColor(.secondary)
    }

    /// Settings' home at regular width — the top bar carries no gear, so
    /// this corner is the one visible entry (⌘, works regardless).
    private var footer: some View {
        HStack {
            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .font(DS.Font.control)
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            Spacer()
        }
        .padding(.horizontal, DS.Padding.m)
        .padding(.vertical, DS.Padding.s)
        .frame(maxWidth: .infinity)
        .background(WindowDragRegion())
    }
}

/// Holds the tab as a plain reference: the list hangs the tab's context
/// menu on the row, and a menu host that observed the tab would be
/// re-evaluated on every retitle — rebuilding the menu while it is open.
/// The title lines and the trailing slot observe for themselves.
private struct SidebarRow: View {
    let tab: TerminalTab
    let isActive: Bool
    let showsDevice: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var titleFont: DS.Font {
        isActive ? .labelEmphasis : .label
    }

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("SidebarRow")
        #endif
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.s) {
                VStack(alignment: .leading, spacing: 2) {
                    ObservedTabTitle(tab: tab, font: titleFont)
                    ObservedTabSubtitle(tab: tab, showsDevice: showsDevice)
                }
                // Title and subtitle name one tab: one VoiceOver stop, not
                // two. The row's close button stays its own element.
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                SidebarRowTrailingSlot(attributes: tab.attributes, onClose: onClose)
            }
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.s)
            // Neutral, like the strip's chips: an accent-tinted slab is
            // what the long-press lift used to pick up, and over the
            // terminal it read as a glitch rather than a highlight.
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear),
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        // The tinted slab is the only sign of which tab the window is on.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// A locked row spends the close slot on the padlock — a second glyph
/// beside the × crowds a title that is already two lines. Close stays on
/// the context menu.
private struct SidebarRowTrailingSlot: View {
    @ObservedObject var attributes: TabAttributes
    let onClose: () -> Void

    var body: some View {
        if let lock = attributes.lock {
            TabLockBadge(lock: lock)
                .frame(width: 24, height: 24)
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DS.Font.captionEmphasis)
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Tab")
        }
    }
}

/// A device's header over its tabs: a click folds them away, and the `+`
/// opens another terminal there. Holds the tab manager as a plain
/// reference, like the rows; its name and status observe for themselves.
private struct SidebarGroupHeader: View {
    let tabManager: TabManager
    let hostID: String?
    let tabs: [TerminalTab]
    let isCollapsed: Bool
    let holdsActiveTab: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DS.Padding.xs) {
            Button(action: onToggle) {
                HStack(spacing: DS.Padding.s) {
                    SidebarGroupName(hostID: hostID)
                    if isCollapsed {
                        Text(verbatim: String(tabs.count))
                            .font(DS.Font.caption)
                            .accessibilityHidden(true)
                    }
                    SidebarGroupStatus(stores: tabs.map(\.store))
                    Spacer(minLength: DS.Padding.s)
                    Image(systemName: "chevron.right")
                        .font(DS.Font.captionEmphasis)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .accessibilityHidden(true)
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(
                (isCollapsed ? Text("Collapsed") : Text("Expanded")) + Text(verbatim: ", ") + Text("\(tabs.count) Tabs"),
            )

            NewTabMenu(tabManager: tabManager, scope: .device(hostID: hostID), onOpen: onOpen) {
                Image(systemName: "plus")
                    .font(DS.Font.captionEmphasis)
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Padding.m)
        .padding(.vertical, DS.Padding.xs)
        // A folded group that holds the active tab wears the active row's
        // slab, so the window's tab is never out of sight.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isCollapsed && holdsActiveTab ? Color.primary.opacity(0.12) : Color.clear),
        )
    }
}

/// The device's name, observing the paired devices and this device's own
/// name for itself: a rename reaches the header without re-rendering the
/// rows, whose context menus would rebuild under the pointer.
private struct SidebarGroupName: View {
    let hostID: String?
    @ObservedObject private var remoteHosts = RemoteHostDirectory.shared
    /// Not read: it is here so a rename in Settings ▸ Remote Access redraws
    /// this device's header. The name is `RemoteDeviceIdentity.deviceName`.
    @AppStorage(RemoteDeviceIdentity.chosenNameKey) private var chosenName: String?

    var body: some View {
        Text(verbatim: name)
            .font(DS.Font.captionEmphasis)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var name: String {
        guard let hostID else {
            return RemoteDeviceIdentity.deviceName
        }
        return remoteHosts.paired.first { $0.id == hostID }?.displayName ?? String(localized: "Remote")
    }
}

/// Nothing while the device's tabs are connected; a quiet glyph while one
/// connects, a warning while one has failed.
private struct SidebarGroupStatus: View {
    let stores: [TerminalSessionStore]
    @StateObject private var watcher = SidebarGroupStatusWatcher()

    var body: some View {
        indicator
            .onAppear { watcher.watch(stores) }
            .onChange(of: stores.map(ObjectIdentifier.init)) { _ in watcher.watch(stores) }
    }

    @ViewBuilder
    private var indicator: some View {
        switch watcher.trouble {
        case let .failed(reason)?:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.caption)
                .foregroundColor(.orange)
                .accessibilityLabel(Text(verbatim: reason))
        case .connecting?:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(DS.Font.caption)
                .accessibilityLabel("Connecting…")
        case nil:
            EmptyView()
        }
    }
}

/// What a group's tabs say about reaching their device. One subscription
/// for the group, made when its tabs change rather than on every render:
/// a `$status` publisher sends its value as it is subscribed, and a
/// subscription made in `body` was renewed by the redraw it caused.
@MainActor
private final class SidebarGroupStatusWatcher: ObservableObject {
    enum Trouble: Equatable {
        case connecting
        case failed(String)
    }

    @Published private(set) var trouble: Trouble?
    private var stores: [TerminalSessionStore] = []
    private var subscription: AnyCancellable?

    func watch(_ stores: [TerminalSessionStore]) {
        self.stores = stores
        subscription = Publishers.MergeMany(stores.map { $0.$status.map { _ in () } })
            // `$status` publishes before the value changes: read it a turn later.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.update() }
            }
        update()
    }

    private func update() {
        let statuses = stores.map(\.status)
        let failure = statuses.lazy.compactMap { status -> String? in
            if case let .failed(reason) = status {
                return reason
            }
            return nil
        }.first
        let found: Trouble? = if let failure {
            .failed(failure)
        } else if statuses.contains(.connecting) {
            .connecting
        } else {
            nil
        }
        if found != trouble {
            trouble = found
        }
    }
}
