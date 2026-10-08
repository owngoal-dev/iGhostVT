import SwiftUI
import UIKit

/// Safari-style tab overview: a grid of cards, each showing its tab's
/// surface as it was last seen (`TerminalTab.previewImage`).
struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false
    @State private var window: UIWindow?

    /// Adaptive cards, as many as the width takes. The minimum is what
    /// keeps two per row on the narrowest phones: a 4.7" or 5.4" screen
    /// leaves 343 points for the grid, two 160-point cards and the gap
    /// between them. At 170 the grid fell back to one card per row there,
    /// which once took a width reader and a second, fixed grid to avoid.
    private static let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14),
    ]

    var body: some View {
        ZStack {
            theme.background(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                Text(tabCountLabel)
                    .font(DS.Font.title)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, DS.Padding.m)

                LazyVGrid(columns: Self.columns, spacing: DS.Padding.m) {
                    ForEach(tabManager.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: {
                                tabManager.activeTabID = tab.id
                                dismiss()
                            },
                            onClose: { tabManager.requestClose(tab, from: .closeButton) },
                            tabManager: tabManager,
                            window: window,
                        )
                    }
                    newTabCard
                }
                .padding(DS.Padding.l)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        // Settings presents ON the switcher: dismissing the switcher first
        // and then presenting would race the dismissal animation, the same
        // dead-entry bug the title capsule's context menu had.
        .settingsPresentation(isPresented: $showsSettings)
        // Close-tab confirmations need no copy here: the root's presents on
        // the front-most context, which is this cover while it is up.
        .background(WindowReader(window: $window))
    }

    private var tabCountLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld Tabs", comment: "Count of open tabs, as a heading"),
            tabManager.tabs.count,
        )
    }

    private var newTabCard: some View {
        NewTabMenu(tabManager: tabManager, onOpen: { dismiss() }) {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(
                    theme.hairline(for: colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4]),
                )
                .frame(height: 190)
                .overlay {
                    Image(systemName: "plus")
                        .font(DS.Font.symbol)
                        .foregroundColor(.secondary)
                }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        GlassBarContainer(spacing: DS.Padding.m) {
            HStack {
                // App-level chrome gets the app-level control: the grid's
                // dashed card is already the one `+`, and settings needs a
                // visible home on iPhone beyond the title's long-press.
                Button(action: { showsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(DS.Font.control)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .barGlass(in: Circle())
                }
                .accessibilityLabel("Settings")

                Spacer(minLength: 8)

                // Only with tabs to close: an empty window already says so in
                // the grid, and a dead destructive control beside it reads as
                // a bug.
                if !tabManager.tabs.isEmpty {
                    Button(action: { requestCloseAll() }) {
                        Text("Close All")
                            .font(DS.Font.control)
                            .foregroundColor(.red)
                            .padding(.horizontal, DS.Padding.l)
                            .frame(height: 44)
                            .contentShape(Capsule())
                            .barGlass(in: Capsule())
                    }

                    Spacer(minLength: 8)
                }

                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(DS.Font.controlEmphasis)
                        .padding(.horizontal, DS.Padding.l)
                        .frame(height: 44)
                        .contentShape(Capsule())
                        .barGlass(in: Capsule())
                }
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.top, DS.Padding.s)
            .bottomScreenMargin(DS.Padding.s, minimum: DS.Padding.l)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.primary)
    }

    /// Same rule as a single tab's ×: ask first when running programs would
    /// die, close straight away when there is nothing to lose.
    private func requestCloseAll() {
        guard tabManager.hasRunningPrograms else {
            tabManager.closeAll()
            return
        }
        AlertViewController(
            title: "Close All Tabs?",
            message: "This closes all tabs and stops everything running in them.",
            actions: [
                AlertAction("Cancel"),
                AlertAction("Close All", kind: .highlighted) {
                    tabManager.closeAll()
                },
            ],
        ).present(in: window)
    }
}

/// Holds the tab as a plain reference: the card carries the tab's context
/// menu, and a menu host that observed the tab would be re-evaluated on
/// every retitle — rebuilding the menu while it is open. The titles, the
/// padlock and the picture observe for themselves.
private struct TabCard: View {
    let tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let tabManager: TabManager
    let window: UIWindow?
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var textPreview = ""

    static let previewHeight: CGFloat = 156

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("TabCard")
        #endif
        VStack(spacing: 0) {
            header
            TabCardPreview(tab: tab, textPreview: textPreview)
        }
        .background(theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(
                    isActive ? Color.accentColor : theme.hairline(for: colorScheme),
                    lineWidth: isActive ? 2 : 1,
                )
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .contextMenu {
            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
        }
        .onTapGesture(perform: onSelect)
        .onAppear {
            // Read only for the card with no picture; the viewport text is
            // a synchronous read of the surface, not worth doing for every
            // card in the grid.
            if tab.previewImage == nil {
                textPreview = tab.snapshotPreview()
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Padding.xs) {
            VStack(alignment: .leading, spacing: 1) {
                ObservedTabTitle(tab: tab, font: .captionEmphasis)
                ObservedTabSubtitle(tab: tab)
            }
            // The card selects on a tap gesture, which VoiceOver cannot
            // reach, and the picture below is hidden: without this the grid
            // offers no way to switch tabs at all. Combining the two titles
            // gives the card one stop that carries the tap as its action;
            // the close button beside it stays its own element.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { onSelect() }
            Spacer(minLength: 4)
            ObservedTabLockBadge(attributes: tab.attributes)
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
        .padding(.horizontal, DS.Padding.m)
        .padding(.vertical, DS.Padding.s)
        .background(Color.primary.opacity(0.06))
    }
}

/// The card's picture. The picture is a still: what the surface showed
/// when this tab was last on screen (or as the switcher opened, for the
/// active one). It is not retaken on redraws behind the cover — toggling
/// the appearance from the switcher's settings recolours the card, not the
/// picture. Its own view because `previewImage` is published by the tab,
/// which the card must not observe.
private struct TabCardPreview: View {
    @ObservedObject var tab: TerminalTab
    let textPreview: String

    var body: some View {
        if let image = tab.previewImage {
            // Filling the card and anchored at its top-leading corner: the
            // prompt and the start of each line are the part that
            // identifies a terminal, and the frame keeps the grid's row
            // height whatever the surface's aspect. A surface wider than
            // the card — any landscape window — loses its right-hand side;
            // centred, it lost the start of every line instead.
            Color.clear
                .frame(height: TabCard.previewHeight)
                .overlay(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .accessibilityHidden(true)
        } else {
            Text(textPreview.isEmpty ? " " : textPreview)
                .font(.system(size: 7, design: .monospaced))
                .lineSpacing(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DS.Padding.s)
                .clipped()
                .frame(height: TabCard.previewHeight)
                .accessibilityHidden(true)
        }
    }
}
