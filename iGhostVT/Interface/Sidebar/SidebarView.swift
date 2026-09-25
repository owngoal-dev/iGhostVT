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
    @StateObject private var draggedTab = DraggedTab()
    /// The rows' width, so a row's drag preview is the row's size.
    @State private var rowWidth: CGFloat = 0

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
            #endif

            ScrollView {
                // Not lazy: a window has tens of tabs at most, nothing here
                // is worth deferring, and a plain stack keeps every row's
                // drag and drop hooks mounted while a reorder moves them.
                VStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        SidebarRow(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { tabManager.requestClose(tab) },
                            tabManager: tabManager,
                            window: window,
                        )
                        .tabReorderable(tab, in: tabManager, dragged: draggedTab, preview: .row, width: rowWidth)
                    }

                    NewTabMenu(tabManager: tabManager) {
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
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarRowWidthKey.self,
                            value: proxy.size.width - DS.Padding.m * 2,
                        )
                    },
                )
                .onPreferenceChange(SidebarRowWidthKey.self) { rowWidth = $0 }
                .tabReorderContainer(dragged: draggedTab)
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

    /// The top bar's height, so the list starts level with the terminal
    /// under the bar and the toggle sits at the bar's own inset from the
    /// window's top, as it does in the bar.
    private var header: some View {
        HStack(spacing: DS.Padding.s) {
            Text(verbatim: "iGhostVT")
                .font(DS.Font.title)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, DS.Padding.s)
            Spacer()
            Text(countLabel)
                .font(DS.Font.caption)
                .foregroundColor(.secondary)
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

    private var countLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld Tabs", comment: "Count of open tabs, as a heading"),
            tabManager.tabs.count,
        )
    }
}

private struct SidebarRow: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let tabManager: TabManager
    let window: UIWindow?

    private var titleFont: DS.Font {
        isActive ? .labelEmphasis : .label
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tab.secondaryTitle)
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Title and subtitle name one tab: one VoiceOver stop, not
                // two. The row's close button stays its own element.
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                // A locked row spends the close slot on the padlock — a
                // second glyph beside the × crowds a title that is already
                // two lines. Close stays on the context menu.
                if let lock = tab.lock {
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
        .contextMenu {
            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
        }
    }
}

private struct SidebarRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
