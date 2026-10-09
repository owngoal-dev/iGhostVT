import SwiftUI
import UIKit

/// Safari-style floating bottom cluster for compact width. Empty: `+`
/// and settings. With a tab: the title capsule, the same ⋯ menu as the
/// iPad strip, and the tab switcher.
struct BottomBar: View {
    @ObservedObject var tabManager: TabManager
    let onShowSettings: () -> Void
    let onShowSwitcher: () -> Void
    @State private var window: UIWindow?
    @StateObject private var newTabRows = NewTabMenuRows()

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.m) {
            // The two clusters swap as the last tab closes or the first one
            // opens, inside the tab list's animation. Each fades as a whole
            // (`glassMaterializes`): left to the container, the title capsule
            // melted into the `+` and the buttons split into blobs between.
            HStack(spacing: DS.Padding.m) {
                if let activeIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.activeTabID }) {
                    Group {
                        TitleCapsule(
                            tabs: tabManager.tabs,
                            activeIndex: activeIndex,
                            onSwitch: { offset in
                                tabManager.activateAdjacentTab(offset: offset)
                            },
                        )
                        overflowMenu
                        switcherButton
                    }
                    .glassMaterializes()
                    .transition(.opacity)
                } else {
                    emptyCluster
                        .glassMaterializes()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.top, DS.Padding.s)
            .bottomScreenMargin(DS.Padding.xs, minimum: DS.Padding.l)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.primary)
        .background(WindowReader(window: $window))
    }

    /// No tab: a new one, and settings.
    @ViewBuilder
    private var emptyCluster: some View {
        NewTabMenu(tabManager: tabManager) {
            Image(systemName: "plus")
                .font(DS.Font.control)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .barGlass(in: Circle())
        }

        Button(action: onShowSettings) {
            Image(systemName: "gearshape")
                .font(DS.Font.control)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .barGlass(in: Circle())
        }
        .accessibilityLabel("Settings")
    }

    private var overflowMenu: some View {
        Menu {
            TabOverflowMenuContent(tabManager: tabManager, window: window, newTabRows: newTabRows)
        } label: {
            Image(systemName: "ellipsis")
                .font(DS.Font.control)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .barGlass(in: Circle())
        }
        .takesNewTabRows(newTabRows, from: tabManager)
        .accessibilityLabel("Tab Menu")
    }

    private var switcherButton: some View {
        Button(action: onShowSwitcher) {
            Image(systemName: "square.on.square")
                .font(DS.Font.control)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if tabManager.tabs.count > 1 {
                        Text("\(tabManager.tabs.count)")
                            .font(DS.Font.captionEmphasis)
                            .padding(DS.Padding.xs)
                            .background(Color.accentColor, in: Circle())
                            .foregroundColor(.white)
                            .offset(x: 2, y: 2)
                            // The badge is the button's value, spelled out
                            // below; read as art it is a bare number.
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
                .barGlass(in: Circle())
        }
        .accessibilityLabel("Show All Tabs")
        .accessibilityValue(tabCountValue)
    }

    /// What the count badge says, as words — and said whether or not the
    /// badge is showing, since one tab is worth announcing too.
    private var tabCountValue: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld Tabs", comment: "Count of open tabs, as a heading"),
            tabManager.tabs.count,
        )
    }
}

/// The active tab's title, and the way to its neighbours: dragged sideways
/// the label follows the finger inside the capsule with the neighbour's
/// coming in behind it, as Safari's address bar does, and let go past a
/// third of the way (or flicked) it lands on that tab. Dragging left goes
/// to the next tab. It does not wrap — at either end the label only
/// stretches and settles back.
private struct TitleCapsule: View {
    let tabs: [TerminalTab]
    let activeIndex: Int
    let onSwitch: (Int) -> Void

    @State private var dragOffset: CGFloat = 0
    /// Decided by the drag's first movement: a vertical start is not a
    /// swipe and is left alone until the finger lifts.
    @State private var isHorizontal: Bool?

    var body: some View {
        // The active label, unseen, gives the capsule its height; the
        // labels that are drawn ride over it.
        TitleCapsuleLabel(tab: tabs[activeIndex])
            .hidden()
            .overlay(
                GeometryReader { proxy in
                    // A neighbour's label sits one capsule-width away.
                    let pageWidth = max(proxy.size.width, 1)
                    ZStack {
                        // Keyed by tab, not by slot, so a switch moves the
                        // same label from where it is rather than swapping
                        // one in.
                        ForEach(slots, id: \.tab.id) { slot in
                            TitleCapsuleLabel(tab: slot.tab)
                                .offset(x: dragOffset + CGFloat(slot.position) * pageWidth)
                                // The neighbours are scenery until they arrive.
                                .accessibilityHidden(slot.position != 0)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Capsule())
                    .highPriorityGesture(swipe(pageWidth: pageWidth))
                },
            )
            .clipShape(Capsule())
            .barGlass(in: Capsule())
    }

    private struct Slot {
        let tab: TerminalTab
        let position: Int
    }

    /// The active tab and whichever neighbours it has.
    private var slots: [Slot] {
        (-1 ... 1).compactMap { position in
            let index = activeIndex + position
            return tabs.indices.contains(index) ? Slot(tab: tabs[index], position: position) : nil
        }
    }

    private func swipe(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let translation = value.translation
                if isHorizontal == nil {
                    isHorizontal = abs(translation.width) > abs(translation.height)
                }
                guard isHorizontal == true else { return }
                dragOffset = hasNeighbor(toward: translation.width)
                    ? translation.width
                    : rubberBand(translation.width, pageWidth: pageWidth)
            }
            .onEnded { value in
                defer { isHorizontal = nil }
                guard isHorizontal == true else { return }
                let travel = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let commits = hasNeighbor(toward: travel)
                    && (abs(travel) > pageWidth / 3
                        || (abs(predicted) > pageWidth / 2 && predicted.sign == travel.sign))
                guard commits else {
                    withAnimation(DS.Motion.snappy) { dragOffset = 0 }
                    return
                }
                let offset = travel < 0 ? 1 : -1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // The arriving label is drawn where the finger left it: the
                // active index moves by one page, the offset back by one, and
                // the spring carries both labels the rest of the way.
                withAnimation(DS.Motion.snappy) {
                    onSwitch(offset)
                    dragOffset = 0
                }
            }
    }

    private func hasNeighbor(toward translation: CGFloat) -> Bool {
        tabs.indices.contains(activeIndex + (translation < 0 ? 1 : -1))
    }

    /// Resistance at an end: the label gives a little and no more.
    private func rubberBand(_ translation: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let limit = pageWidth / 4
        let distance = abs(translation)
        return (limit * distance / (distance + limit)) * (translation < 0 ? -1 : 1)
    }
}

private struct TitleCapsuleLabel: View {
    let tab: TerminalTab

    var body: some View {
        // The title alone: a phone's capsule is narrow, and the process
        // and device beside it left the title a few letters and an
        // ellipsis. The strip, the sidebar and the switcher still show them.
        HStack(spacing: DS.Padding.s) {
            ObservedTabLockBadge(attributes: tab.attributes)
            ObservedTabTitle(tab: tab)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, DS.Padding.l)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}
