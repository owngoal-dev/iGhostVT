//
//  TabStripBar.swift
//  iGhostVT
//

import SwiftUI

/// Safari-for-iPad-style top bar for regular width. With the sidebar closed
/// it shows scrollable tab chips; with the sidebar open the tabs live there
/// and this bar shows the active tab's title instead.
struct TabStripBar: View {
    /// The bar's height: its controls plus the padding above and below.
    /// The Mac's traffic lights are centred on it (`CatalystWindowChrome`).
    static let height: CGFloat = DS.Padding.s + controlSize + DS.Padding.s
    static let controlSize: CGFloat = 40

    @ObservedObject var tabManager: TabManager
    @Binding var showsSidebar: Bool
    @State private var window: UIWindow?
    @StateObject private var draggedTab = DraggedTab()

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.s) {
            HStack(spacing: DS.Padding.s) {
                // With the sidebar open the toggle sits in the sidebar's own
                // top strip, beside the separator (`SidebarView`).
                if !showsSidebar {
                    SidebarToggleButton(showsSidebar: $showsSidebar)
                        .barGlass(in: Circle())
                }

                if tabManager.tabs.isEmpty {
                    // With no tabs there is nothing to title or strip: an
                    // empty capsule collapses to its padding — an 8pt line
                    // squashed across the bar — so the empty state yields the
                    // space instead.
                    Spacer()
                } else {
                    centerCapsule
                }

                // The bar's only trailing control: the active tab's menu,
                // with New Tab at its head. The sidebar owns settings and
                // doubles as the tab overview at this width, so the strip
                // carries neither entry.
                Menu {
                    TabOverflowMenuContent(tabManager: tabManager, window: window)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Tab Menu")
            }
            // One inset all round: the controls sit as far from the window's
            // side as from its top edge.
            .padding(.horizontal, DS.Padding.s)
            .padding(.leading, windowControlsInset)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.s)
            .background(WindowDragRegion())
        }
        .buttonStyle(.plain)
        // For the context menu's share sheet, which presents via UIKit.
        .background(WindowReader(window: $window))
    }

    /// With the sidebar hidden, the Mac's traffic lights float over this
    /// bar's leading end; the sidebar toggle moves out from under them, and
    /// the bar's horizontal padding is then the gap to the lights — the
    /// same 8pt the toggle keeps from the capsule on its other side. With
    /// the sidebar open it clears them itself and the bar starts flush.
    private var windowControlsInset: CGFloat {
        #if targetEnvironment(macCatalyst)
            showsSidebar ? 0 : CatalystWindowChrome.windowControlsEnd
        #else
            0
        #endif
    }

    /// One capsule for both modes. The bar is a glass-effect container, and
    /// replacing a glass capsule with another one makes Liquid Glass morph
    /// between them — a blob that shrinks to a pill and regrows while the
    /// sidebar slides. The shape stays mounted; only its content crossfades.
    private var centerCapsule: some View {
        // Leading, like the chips: a program that retitles on every prompt
        // (a status line, an agent reporting progress) would otherwise
        // re-centre the text at each change.
        ZStack(alignment: .leading) {
            if showsSidebar {
                if let tab = tabManager.activeTab {
                    HStack(spacing: DS.Padding.s) {
                        ObservedTabTitle(tab: tab)
                        ObservedTabSubtitle(tab: tab)
                    }
                    // Title and subtitle name one tab: VoiceOver reads them
                    // as one stop rather than stopping twice on the capsule.
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal, DS.Padding.l)
                    .contextMenu {
                        TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                    }
                    // Keyed on the tab: switching tabs (a new one included)
                    // crossfades one title for another. Without the key
                    // SwiftUI reads it as the same text changing and morphs
                    // the two — strings overlapping mid-slide.
                    .id(tab.id)
                    .transition(.opacity)
                }
            } else {
                chipStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
        .barGlass(in: Capsule(), interactive: false)
    }

    /// Chips share the bar Safari-style: equal widths, the bar divided by
    /// the tab count and clamped to ``TabChip/widthRange``, so a title that
    /// keeps changing never resizes its chip or shoves its neighbours, and
    /// the strip scrolls only once the minimums no longer fit.
    private var chipStrip: some View {
        GeometryReader { proxy in
            let count = CGFloat(max(tabManager.tabs.count, 1))
            let available = proxy.size.width - DS.Padding.xs * 2 - DS.Padding.xs * (count - 1)
            let width = min(TabChip.widthRange.upperBound, max(TabChip.widthRange.lowerBound, available / count))
            ChipScroller {
                HStack(spacing: DS.Padding.xs) {
                    ForEach(tabManager.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { tabManager.requestClose(tab) },
                        )
                        .frame(width: width)
                        .contextMenu {
                            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                        }
                        .tabReorderable(tab, in: tabManager, dragged: draggedTab, preview: .chip, width: width)
                    }
                }
                .padding(DS.Padding.xs)
                .tabReorderContainer(dragged: draggedTab)
            }
        }
        // A GeometryReader fills whatever it is given, in both axes; the
        // bar's height is the capsule's, not the window's.
        .frame(maxWidth: .infinity, maxHeight: Self.controlSize, alignment: .leading)
    }
}

/// Title text that re-renders when the surface retitles (OSC updates).
struct ObservedTabTitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Text(tab.displayTitle)
            .font(DS.Font.labelEmphasis)
            .lineLimit(1)
            .truncationMode(.middle)
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.displayTitle)
    }
}

/// The dim line beside the title: what the session reports about itself
/// while the title itself stays the stable process name.
struct ObservedTabSubtitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Text(tab.secondaryTitle)
            .font(DS.Font.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.secondaryTitle)
    }
}

private extension View {
    /// A retitle crossfades the text instead of swapping it. The shell
    /// retitles a fresh tab within a second of its prompt appearing, so
    /// "Terminal" turning into a host name is the first thing a new tab
    /// does — worth more than a hard cut.
    @ViewBuilder
    func retitleTransition() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// The floor keeps room for a title beside the close button — a tap on
    /// the chip's leading half must select, not close; the ceiling keeps
    /// one long title from owning the bar.
    static let widthRange: ClosedRange<CGFloat> = 120 ... 240

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.xs) {
                Text(tab.displayTitle)
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .retitleTransition()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lock = tab.lock {
                    TabLockBadge(lock: lock)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, DS.Padding.m)
            .frame(height: 32)
            .background(
                Capsule().fill(
                    isActive ? Color.primary.opacity(0.12) : Color.clear,
                ),
            )
            .contentShape(Capsule())
            // A retitle changes the chip's width; the chips after it slide
            // over instead of jumping.
            .animation(DS.Motion.smooth, value: tab.displayTitle)
        }
        // Without it a chip gives VoiceOver no way to tell which tab the
        // strip is on. The close button inside stays its own element.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// The chips' horizontal scroller. On the Mac this is a plain clipped row:
/// a `ScrollView` (a `UIScrollView` underneath) inside the bar's glass
/// container renders its content *under* the glass on macOS 27 — the chips
/// came up as a frosted blank capsule — so the chips are laid out directly
/// and the row clips at the capsule's edge. Elsewhere it scrolls.
private struct ChipScroller<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if targetEnvironment(macCatalyst)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        #else
            ScrollView(.horizontal, showsIndicators: false, content: content)
        #endif
    }
}
