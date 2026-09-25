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

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.m) {
            HStack(spacing: DS.Padding.m) {
                if let tab = tabManager.activeTab {
                    TitleCapsule(tab: tab)
                        .highPriorityGesture(switchTabGesture)
                    overflowMenu
                    switcherButton
                } else {
                    NewTabMenu(tabManager: tabManager) {
                        Image(systemName: "plus")
                            .font(DS.Font.control)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .barGlass(in: Circle())

                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape")
                            .font(DS.Font.control)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .barGlass(in: Circle())
                    .accessibilityLabel("Settings")
                }
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.xs)
        }
        .buttonStyle(.plain)
        .background(WindowReader(window: $window))
    }

    private var overflowMenu: some View {
        Menu {
            TabOverflowMenuContent(tabManager: tabManager, window: window)
        } label: {
            Image(systemName: "ellipsis")
                .font(DS.Font.control)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .barGlass(in: Circle())
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
        }
        .barGlass(in: Circle())
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

    private var switchTabGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                withAnimation(DS.Motion.snappy) {
                    tabManager.activateAdjacentTab(
                        offset: value.translation.width < 0 ? 1 : -1,
                    )
                }
            }
    }
}

private struct TitleCapsule: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        HStack(spacing: DS.Padding.s) {
            Text(tab.displayTitle)
                .font(DS.Font.labelEmphasis)
                .lineLimit(1)
                .truncationMode(.middle)
            ObservedTabSubtitle(tab: tab)
        }
        // Title and subtitle name one tab: one VoiceOver stop, not two.
        .accessibilityElement(children: .combine)
        .padding(.horizontal, DS.Padding.l)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Capsule())
        .barGlass(in: Capsule())
    }
}
