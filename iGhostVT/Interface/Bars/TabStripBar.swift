//
//  TabStripBar.swift
//  iGhostVT
//

import SwiftUI
#if !targetEnvironment(macCatalyst)
    import UIKit.UIGestureRecognizerSubclass
#endif

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
    @StateObject private var newTabRows = NewTabMenuRows()
    @Environment(\.windowControlsLeading) private var windowControlsLeading
    /// The chip strip's width, for `reveal` to tell whether it scrolls.
    @State private var stripWidth: CGFloat = 0
    /// The chip lifted by a long press, if any.
    @State private var chipDrag: ChipDrag?
    #if targetEnvironment(macCatalyst)
        /// True while a press on a chip is held; its fall back to false is
        /// what settles a lifted chip whose gesture ended without `onEnded`.
        @GestureState private var isChipPressed = false
        /// True while a plain drag on a chip is moving the window.
        @GestureState private var isMovingWindow = false
    #endif

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
                    TabOverflowMenuContent(tabManager: tabManager, window: window, newTabRows: newTabRows)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                }
                .barGlass(in: Circle())
                .takesNewTabRows(newTabRows, from: tabManager)
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
            // A windowed iPad's own controls, the same way.
            showsSidebar ? 0 : windowControlsLeading
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
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
        // On the Mac the capsule is most of the title bar: a drag on the
        // title, or between chips, moves the window as a title bar would.
        .background(WindowDragRegion())
        .barGlass(in: Capsule(), interactive: false)
    }

    /// Chips share the bar Safari-style: equal widths, the bar divided by
    /// the tab count (``TabChip/width(sharing:among:)``), so a title that
    /// keeps changing never resizes its chip or shoves its neighbours, and
    /// the strip scrolls only once the minimums no longer fit.
    private var chipStrip: some View {
        GeometryReader { proxy in
            let width = chipLayout(in: proxy.size.width).width
            ScrollViewReader { scroller in
                ChipScroller(isScrollDisabled: chipDrag != nil) {
                    HStack(spacing: DS.Padding.xs) {
                        ForEach(tabManager.tabs) { tab in
                            TabChip(
                                tab: tab,
                                isActive: tab.id == tabManager.activeTabID,
                                showsSelection: tabManager.tabs.count > 1,
                                lift: lift(of: tab),
                                onSelect: { tabManager.activeTabID = tab.id },
                                onClose: { tabManager.requestClose(tab, from: .closeButton) },
                            )
                            .frame(width: width)
                            #if targetEnvironment(macCatalyst)
                            // A touch screen's long press is the reorder,
                            // and nothing else: a menu that opened when the
                            // finger held still took the chip from under a
                            // reorder. The ⋯ button has the same menu.
                            .contextMenu {
                                TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                            }
                            #endif
                            .offset(x: chipDragOffset(for: tab, pitch: width + DS.Padding.xs))
                            .scaleEffect(chipDrag?.id == tab.id ? Self.liftedChipScale : 1)
                            .zIndex(chipDrag?.id == tab.id ? 1 : 0)
                            // The dragged chip rides the pointer; only its
                            // neighbours slide into their new slots. A change
                            // of destination (`DS.Motion.snappy`) still
                            // animates, so leaving and rejoining the strip
                            // glide instead of jumping.
                            .transaction { transaction in
                                if let chipDrag, chipDrag.id == tab.id, chipDrag.isMoving,
                                   transaction.animation != DS.Motion.snappy
                                {
                                    transaction.animation = nil
                                }
                            }
                            #if targetEnvironment(macCatalyst)
                            // Beside the chip's button, not over it: a
                            // press it outranked never reached the button,
                            // and a click stopped selecting the tab.
                            .simultaneousGesture(chipGesture(for: tab, pitch: width + DS.Padding.xs, scroller: scroller))
                            #endif
                            .id(tab.id)
                        }
                    }
                    .padding(DS.Padding.xs)
                    // The gaps between chips are bare chrome too.
                    .background(WindowDragRegion())
                    #if !targetEnvironment(macCatalyst)
                        .background(
                            ChipPressRecognizer(
                                onLift: { x in
                                    let index = Int((x - DS.Padding.xs) / (width + DS.Padding.xs))
                                    guard tabManager.tabs.indices.contains(index) else { return false }
                                    lift(tabManager.tabs[index])
                                    return true
                                },
                                onMove: { translation in
                                    guard let tab = liftedTab else { return }
                                    moveLiftedChip(tab, by: translation, pitch: width + DS.Padding.xs, scroller: scroller)
                                },
                                onEnd: { dropped in
                                    if dropped {
                                        dropLiftedChip()
                                    }
                                    settleChipDrag(scroller: scroller)
                                },
                            ),
                        )
                    #endif
                }
                .onAppear {
                    stripWidth = proxy.size.width
                    reveal(with: scroller, animated: false)
                }
                .onChange(of: proxy.size.width) { stripWidth = $0 }
                #if targetEnvironment(macCatalyst)
                    .onChange(of: isChipPressed) { pressed in
                        if !pressed {
                            settleChipDrag(scroller: scroller)
                        }
                    }
                    .onChange(of: isMovingWindow) { moving in
                        if !moving {
                            window?.endWindowMovement()
                        }
                    }
                #endif
                    .onChange(of: tabManager.activeTabID) { _ in reveal(with: scroller, animated: true) }
                    // A resize or a tab opened or closed changes every chip's
                    // width, and the active one can slide out of view with it.
                    .onChange(of: width) { _ in reveal(with: scroller, animated: false) }
            }
        }
        // A GeometryReader fills whatever it is given, in both axes; the
        // bar's height is the capsule's, not the window's.
        .frame(maxWidth: .infinity, maxHeight: Self.controlSize, alignment: .leading)
    }

    /// How `tab`'s chip is lifted off the strip by a drag, if it is.
    private func lift(of tab: TerminalTab) -> ChipLift? {
        guard let chipDrag, chipDrag.id == tab.id else { return nil }
        switch chipDrag.destination {
        case .strip: return .reordering
        case .newWindow: return .toNewWindow
        case .window: return .toOtherWindow
        }
    }

    /// Where the dragged chip is drawn relative to the slot it now
    /// holds: the pointer's travel, less the slots it has already moved.
    /// A chip on its way out of the window sits back in its slot instead —
    /// travel along this strip means nothing then, and carried sideways it
    /// was clipped at the strip's end, arrow and all.
    private func chipDragOffset(for tab: TerminalTab, pitch: CGFloat) -> CGFloat {
        guard let chipDrag, chipDrag.id == tab.id, chipDrag.destination == .strip,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
        else { return 0 }
        return chipDrag.travel - CGFloat(index - chipDrag.startIndex) * pitch
    }

    /// A chip is picked up by a long press, never by a plain drag, which
    /// has another job: on the Mac the strip is the title bar and a drag
    /// moves the window, and on a touch screen it scrolls the strip. The
    /// long press lifts the chip onto a capsule of its own. Lifted, it
    /// follows the pointer and trades places with a neighbour once it is
    /// past that neighbour's middle; carried past the strip's end it keeps
    /// trading, and the strip scrolls to keep it in view. Where it is let
    /// go decides the rest (`ChipDestination`), and its close button turns
    /// into the arrow that says which: pulled out of the bar it opens a
    /// window of its own, on the Mac over another window's bar it joins
    /// that window (`TabWindowMove`), and brought back into its own bar it
    /// is only being reordered again.
    ///
    /// Not the system drag the sidebar uses. On the Mac the strip lives in
    /// the band AppKit keeps for a title bar, and a system drag over that
    /// band never reaches the content as a drop target; on iPadOS a chip's
    /// system drag began as the finger moved, so a swipe along the strip
    /// picked up a tab instead of scrolling. The Mac's press is a SwiftUI
    /// gesture (below); a touch screen's is `ChipPressRecognizer`, since
    /// any SwiftUI gesture on a chip kept the strip from scrolling.
    private func lift(_ tab: TerminalTab) {
        guard chipDrag?.id != tab.id,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        withAnimation(DS.Motion.snappy) {
            chipDrag = ChipDrag(id: tab.id, startIndex: index)
        }
    }

    /// The tab whose chip is lifted, if it is still in this window.
    private var liftedTab: TerminalTab? {
        guard let chipDrag else { return nil }
        return tabManager.tabs.first { $0.id == chipDrag.id }
    }

    /// Lets go of the lifted chip where it is headed.
    private func dropLiftedChip() {
        guard let chipDrag, let tab = liftedTab else { return }
        drop(tab, at: chipDrag.destination)
    }

    #if targetEnvironment(macCatalyst)
        private func chipGesture(for tab: TerminalTab, pitch: CGFloat, scroller: ScrollViewProxy) -> some Gesture {
            let reorder = LongPressGesture(minimumDuration: Self.reorderPressDuration, maximumDistance: 4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($isChipPressed) { _, pressed, _ in pressed = true }
                .onChanged { value in
                    guard case let .second(true, drag) = value else { return }
                    lift(tab)
                    if let drag {
                        moveLiftedChip(tab, by: drag.translation, pitch: pitch, scroller: scroller)
                    }
                }
                .onEnded { _ in
                    dropLiftedChip()
                    settleChipDrag(scroller: scroller)
                }
            let moveWindow = DragGesture(minimumDistance: 4)
                .updating($isMovingWindow) { _, moving, _ in moving = true }
                .onChanged { _ in window?.dispatchTouchAsWindowMovement() }
            return reorder.exclusively(before: moveWindow)
        }
    #endif

    private func moveLiftedChip(_ tab: TerminalTab, by translation: CGSize, pitch: CGFloat, scroller: ScrollViewProxy) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        chipDrag?.isMoving = true
        chipDrag?.travel = translation.width
        let destination = destination(of: tab, pulledBy: translation.height)
        if chipDrag?.destination != destination {
            withAnimation(DS.Motion.snappy) { chipDrag?.destination = destination }
        }
        // Out of the bar the chip is on its way to another window; its
        // neighbours stay where they are.
        guard destination == .strip else { return }
        let offset = chipDragOffset(for: tab, pitch: pitch)
        let tabs = tabManager.tabs
        if offset > pitch / 2, index + 1 < tabs.count {
            tabManager.moveTab(tab, toSlotOf: tabs[index + 1])
        } else if offset < -pitch / 2, index > 0 {
            tabManager.moveTab(tab, toSlotOf: tabs[index - 1])
        } else {
            return
        }
        scroller.scrollTo(tab.id)
    }

    /// Where a lifted chip would go if let go now. On the Mac another
    /// window's bar under the pointer wins; then a pull out of this bar,
    /// for a tab that can leave its window; otherwise the strip.
    private func destination(of tab: TerminalTab, pulledBy pull: CGFloat) -> ChipDestination {
        #if targetEnvironment(macCatalyst)
            if TabWindowMove.canMerge(tab), let target = windowBarUnderPointer() {
                return .window(target)
            }
        #endif
        if abs(pull) > Self.tearOffDistance, TabWindowMove.canMove(tab, in: tabManager) {
            return .newWindow
        }
        return .strip
    }

    private func drop(_ tab: TerminalTab, at destination: ChipDestination) {
        switch destination {
        case .strip:
            return
        case .newWindow:
            TabWindowMove.moveToNewWindow(tab, from: tabManager, origin: newWindowOrigin())
        case let .window(target):
            TabWindowMove.merge(tab, from: tabManager, into: target)
        }
    }

    /// Puts a lifted chip down in the slot it holds. Runs from the
    /// gesture's end and again as the press state falls back, since a
    /// cancelled gesture never reaches `onEnded`; the second is a no-op.
    private func settleChipDrag(scroller: ScrollViewProxy) {
        guard let chipDrag else { return }
        withAnimation(DS.Motion.smooth) {
            self.chipDrag = nil
            scroller.scrollTo(chipDrag.id)
        }
    }

    /// Where a window opened by a drop puts its top-left corner: on the
    /// Mac, so its first chip comes up under the pointer, as if carried
    /// there. Elsewhere the system places windows.
    private func newWindowOrigin() -> CGPoint? {
        #if targetEnvironment(macCatalyst)
            CatalystWindowChrome.pointerLocation.map {
                CGPoint(
                    x: $0.x - CatalystWindowChrome.screenDistance(Self.newWindowGrabOffset.width),
                    y: $0.y + CatalystWindowChrome.screenDistance(Self.newWindowGrabOffset.height),
                )
            }
        #else
            nil
        #endif
    }

    #if targetEnvironment(macCatalyst)
        /// The other window whose top bar is under the pointer, if any. The
        /// pointer over this window counts as this window, whatever lies
        /// behind it.
        private func windowBarUnderPointer() -> TabManager? {
            guard let pointer = CatalystWindowChrome.pointerLocation else { return nil }
            if let own = tabManager.windowScene, let frame = CatalystWindowChrome.frame(of: own), frame.contains(pointer) {
                return nil
            }
            return TabWindowMove.otherWindows(than: tabManager).first { other in
                guard let scene = other.windowScene, let frame = CatalystWindowChrome.frame(of: scene) else { return false }
                return CatalystWindowChrome.barContains(pointer, inWindowFrame: frame)
            }
        }

        /// Where, in a new window, the pointer holds it: over the first
        /// chip of a strip whose sidebar is hidden.
        private static let newWindowGrabOffset = CGSize(
            width: CatalystWindowChrome.windowControlsEnd + DS.Padding.s * 2 + controlSize + 60,
            height: height / 2,
        )
    #endif

    /// How long a chip is held before it lifts; a drag that starts sooner
    /// moves the window on the Mac and scrolls the strip elsewhere.
    static let reorderPressDuration: Double = 0.3
    /// How far out of the bar a lifted chip is pulled before releasing it
    /// opens a new window: past the bar's own controls.
    private static let tearOffDistance: CGFloat = controlSize
    private static let liftedChipScale: CGFloat = 1.04

    /// Scrolls the active chip into view — a tab picked from the sidebar,
    /// the menu or a shortcut may sit past the strip's visible end. The
    /// nearest edge, not the centre: a chip already showing stays put. A
    /// strip that fits is put back at its start instead, since every chip
    /// shows there.
    ///
    /// Asked twice: now, and again once a tab's arrival or departure has
    /// finished animating. The scroll view's content size follows that
    /// animation, so a scroll asked for mid-flight is clamped to a size
    /// that is about to change — at the point where a new tab makes the
    /// strip start scrolling, the new chip stayed half hidden, and where a
    /// strip stopped scrolling it kept an offset its content no longer had.
    ///
    /// Whether the strip fits is read when each scroll runs, from the live
    /// tab count and `stripWidth`: an `onChange` action runs with the values
    /// of the body that installed it, and a captured answer was the one from
    /// before the tab that tipped the strip into scrolling.
    private func reveal(with scroller: ScrollViewProxy, animated: Bool) {
        let scroll = {
            if chipLayout(in: stripWidth).fits, let first = tabManager.tabs.first {
                scroller.scrollTo(first.id, anchor: .leading)
            } else if let id = tabManager.activeTabID {
                scroller.scrollTo(id)
            }
        }
        if animated {
            withAnimation(DS.Motion.smooth, scroll)
        } else {
            scroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabTransitionSettle) {
            withAnimation(DS.Motion.smooth, scroll)
        }
    }

    /// The chips' shared width in a strip `stripWidth` wide, and whether
    /// they fit it without scrolling.
    private func chipLayout(in stripWidth: CGFloat) -> (width: CGFloat, fits: Bool) {
        let count = CGFloat(max(tabManager.tabs.count, 1))
        let available = stripWidth - DS.Padding.xs * 2 - DS.Padding.xs * (count - 1)
        let width = TabChip.width(sharing: available, among: count)
        return (width, width * count <= available)
    }

    /// Long enough for `TabManager.tabTransition` to come to rest.
    private static let tabTransitionSettle: TimeInterval = 0.6
}

/// A chip lifted by a long press: which tab, the slot it was lifted
/// from, how far the pointer has travelled along the strip since, and
/// whether it has been pulled out of the bar.
private struct ChipDrag {
    let id: UUID
    let startIndex: Int
    var travel: CGFloat = 0
    /// Whether the pointer has moved since the lift. Until it does the
    /// lift itself animates; after, the chip tracks the pointer.
    var isMoving = false
    var destination = ChipDestination.strip
}

/// Where a lifted chip goes when it is let go.
private enum ChipDestination: Equatable {
    /// Stays in this strip, in the slot it now holds.
    case strip
    /// Out of the bar: a window of its own, opened where it was dropped.
    case newWindow
    /// Over another window's bar: joins that window. The Mac only, where
    /// the pointer can be over another window at all.
    case window(TabManager)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.strip, .strip), (.newWindow, .newWindow): true
        case let (.window(a), .window(b)): a === b
        default: false
        }
    }
}

/// How a chip is lifted off the strip, which its close button shows: a
/// chip being reordered keeps its ×, one on its way out of the window
/// shows where to.
private enum ChipLift {
    case reordering
    case toNewWindow
    case toOtherWindow

    var trailingSymbol: String {
        switch self {
        case .reordering: "xmark"
        case .toNewWindow: "arrow.up.right"
        case .toOtherWindow: "arrow.down.left"
        }
    }
}

/// Not an observer of the tab: on the Mac the strip hangs the tab's
/// context menu on this view, and a menu host re-evaluated on every
/// retitle rebuilds the menu while it is open. The title and the padlock observe for themselves.
private struct TabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    /// Whether the active chip draws its capsule. A lone tab has nothing to
    /// be picked out from, and a filled chip alone in the strip reads as a
    /// stray button; it is still the selected one to VoiceOver.
    let showsSelection: Bool
    /// Lifted by a drag and drawn over its neighbours, and where it is
    /// headed. An unselected chip is bare text on the bar, and carried
    /// across another one the two titles printed over each other; a
    /// lifted chip carries its own opaque capsule.
    let lift: ChipLift?
    let onSelect: () -> Void
    let onClose: () -> Void

    /// The narrowest a chip gets: wide enough for a window-title's worth of
    /// text beside the close button, so a tap on the chip's leading half
    /// selects rather than closes. Below it the strip scrolls; above it the
    /// chips split the capsule.
    static let minimumWidth: CGFloat = 200

    /// Each chip's width when `count` chips share `available` points: the
    /// chips fill the capsule whatever the count — one tab is one
    /// full-width chip, as in Safari — until a share falls under
    /// ``minimumWidth``, where they stop shrinking and the strip scrolls.
    /// The same on the Mac and the iPad: the iPad's chips used to stop at
    /// 240pt and leave the rest of the capsule bare. The share is rounded
    /// *down* to a 64th of a point: the row then never comes out a hair
    /// wider than its scroller, which would make a strip that fits scroll
    /// by a fraction of a pixel.
    static func width(sharing available: CGFloat, among count: CGFloat) -> CGFloat {
        let share = available / count
        guard share >= minimumWidth else { return minimumWidth }
        return (share * 64).rounded(.down) / 64
    }

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("TabChip")
        #endif
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.xs) {
                ObservedTabTitle(tab: tab, font: .label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ObservedTabLockBadge(attributes: tab.attributes)
                Button(action: onClose) {
                    ChipTrailingSymbol(name: lift?.trailingSymbol ?? "xmark")
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
                    isActive && showsSelection ? Color.primary.opacity(0.12) : Color.clear,
                ),
            )
            .background {
                if lift != nil {
                    LiftedChipBackground()
                }
            }
            .contentShape(Capsule())
        }
        // Without it a chip gives VoiceOver no way to tell which tab the
        // strip is on. The close button inside stays its own element.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// The chip's trailing glyph: the close button's ×, or while the chip is
/// carried out of its window, the arrow saying where it is going. The
/// symbol swaps with the system's replace effect where there is one.
private struct ChipTrailingSymbol: View {
    let name: String

    var body: some View {
        if #available(iOS 17.0, *) {
            Image(systemName: name)
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: name)
                .id(name)
                .transition(.opacity)
        }
    }
}

/// A lifted chip's own capsule: the terminal's background, so the title
/// stays readable over whatever chip it is carried across, with a shadow
/// that sets it above the strip.
private struct LiftedChipBackground: View {
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(theme.background(for: colorScheme))
            .overlay(Capsule().fill(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }
}

/// The chips' horizontal scroller. On the Mac the strip sits in the band
/// AppKit keeps for a title bar, and macOS 26+ draws a scroll view's edge
/// effect over whatever scrolls under that band — the chips came up as a
/// frosted blank capsule, which read as the glass covering them and once
/// had the Mac strip laid out as a clipped row that could not scroll. With
/// the edge effect hidden it scrolls like everywhere else, a mouse wheel
/// included (`WheelScrollsHorizontally`).
private struct ChipScroller<Content: View>: View {
    /// While a chip is lifted the strip holds still under it: the chip's
    /// own drag scrolls it when it is carried past an end.
    let isScrollDisabled: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if targetEnvironment(macCatalyst)
            if #available(iOS 26.0, *) {
                ScrollView(.horizontal, showsIndicators: false, content: wheelScrolledContent)
                    .scrollEdgeEffectHidden()
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false, content: wheelScrolledContent)
            }
        #else
            // A strip that fits holds still under a swipe, as the Mac's
            // does, instead of rubber-banding a row that has nowhere to go.
            if #available(iOS 16.4, *) {
                ScrollView(.horizontal, showsIndicators: false, content: content)
                    .scrollDisabled(isScrollDisabled)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else if #available(iOS 16.0, *) {
                ScrollView(.horizontal, showsIndicators: false, content: content)
                    .scrollDisabled(isScrollDisabled)
            } else {
                ScrollView(.horizontal, showsIndicators: false, content: content)
            }
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func wheelScrolledContent() -> some View {
            content().background(WheelScrollsHorizontally())
        }
    #endif
}

#if !targetEnvironment(macCatalyst)
    /// A touch screen's way to pick up a chip, recognised by the strip's own
    /// scroll view. Placed inside the scroller's content, it finds the
    /// `UIScrollView` SwiftUI built around it and adds the press there.
    /// One touch on a chip can mean three things, and this decides which,
    /// the way the Home Screen does for an icon:
    ///
    /// - moved before the press lifts: a swipe, and the strip scrolls;
    /// - let go before then: a tap, and the chip's button selects it;
    /// - held for ``TabStripBar/reorderPressDuration``: the chip lifts, and
    ///   moved from there it is carried (reorder, or out of the window);
    ///   let go without moving, it settles back.
    ///
    /// A chip has no context menu here (the ⋯ button has it): one that
    /// opened when the finger held still took the chip from under a
    /// reorder. Everything else on the strip — the scroll view's pan, the
    /// button — waits for this one to fail, so neither starts on a touch
    /// that turns out to be a carry. It cancels no touches, so the ones it
    /// lets go reach them as they were.
    private struct ChipPressRecognizer: UIViewRepresentable {
        /// The chip under this point of the strip's content lifts; answers
        /// whether there was a chip there.
        let onLift: (CGFloat) -> Bool
        /// The finger's travel since the press began.
        let onMove: (CGSize) -> Void
        /// The press is over: let go after a carry (`true`), or anything
        /// else that puts a lifted chip back.
        let onEnd: (Bool) -> Void

        func makeUIView(context: Context) -> PressView {
            PressView(coordinator: context.coordinator)
        }

        func updateUIView(_: PressView, context: Context) {
            context.coordinator.parent = self
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        @MainActor
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var parent: ChipPressRecognizer

            init(parent: ChipPressRecognizer) {
                self.parent = parent
            }

            @objc func pressed(_ press: ChipPress) {
                switch press.state {
                case .began, .changed:
                    parent.onMove(press.translation)
                case .ended:
                    parent.onEnd(true)
                case .cancelled:
                    parent.onEnd(false)
                default:
                    break
                }
            }

            /// Asked only of recognizers that share this touch: the strip's
            /// pan and the chip's button. Both wait until the press lets
            /// the touch go — a move before it lifts, or the finger up.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldBeRequiredToFailBy other: UIGestureRecognizer,
            ) -> Bool {
                other !== gestureRecognizer
            }
        }

        final class PressView: UIView {
            private let coordinator: Coordinator
            private weak var scrollView: UIScrollView?
            private lazy var press: ChipPress = {
                let press = ChipPress(target: coordinator, action: #selector(Coordinator.pressed(_:)))
                press.cancelsTouchesInView = false
                press.delegate = coordinator
                press.onLift = { [weak coordinator] x in coordinator?.parent.onLift(x) ?? false }
                press.onSettle = { [weak coordinator] in coordinator?.parent.onEnd(false) }
                return press
            }()

            init(coordinator: Coordinator) {
                self.coordinator = coordinator
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) is not supported")
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                scrollView?.removeGestureRecognizer(press)
                scrollView = nil
                guard window != nil else { return }
                var ancestor = superview
                while let view = ancestor, !(view is UIScrollView) {
                    ancestor = view.superview
                }
                scrollView = ancestor as? UIScrollView
                scrollView?.addGestureRecognizer(press)
            }
        }

        /// The press itself. It stays `.possible` while the chip is merely
        /// lifted — so the touches it may yet give up still wait on it —
        /// and begins only once a lifted chip moves.
        final class ChipPress: UIGestureRecognizer {
            var onLift: ((CGFloat) -> Bool)?
            /// A lifted chip that was not carried goes back.
            var onSettle: (() -> Void)?
            private(set) var translation: CGSize = .zero
            private var start: CGPoint = .zero
            private var isLifted = false
            private var isCarried = false
            /// Where in the strip's content the press began.
            private var pressX: CGFloat = 0
            private var timers: [Timer] = []

            /// A finger is never quite still: how far it may wander and
            /// still be holding, and how far a lifted chip moves before it
            /// counts as carried.
            private static let holdSlop: CGFloat = 10
            private static let carryDistance: CGFloat = 6

            override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
                guard touches.count == 1, numberOfTouches == 1, let touch = touches.first, let view else {
                    state = .failed
                    return
                }
                start = touch.location(in: view.superview)
                pressX = touch.location(in: view).x
                schedule(after: TabStripBar.reorderPressDuration, #selector(liftTimerFired))
            }

            @objc private func liftTimerFired() {
                guard state == .possible else { return }
                isLifted = onLift?(pressX) ?? false
                if !isLifted {
                    state = .failed
                }
            }

            override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent) {
                guard let touch = touches.first, let view else { return }
                let location = touch.location(in: view.superview)
                translation = CGSize(width: location.x - start.x, height: location.y - start.y)
                let distance = hypot(translation.width, translation.height)
                switch state {
                case .possible where !isLifted:
                    if distance > Self.holdSlop {
                        state = .failed
                    }
                case .possible:
                    if distance > Self.carryDistance {
                        isCarried = true
                        state = .began
                    }
                case .began, .changed:
                    state = .changed
                default:
                    break
                }
            }

            override func touchesEnded(_: Set<UITouch>, with _: UIEvent) {
                state = state == .began || state == .changed ? .ended : .failed
            }

            override func touchesCancelled(_: Set<UITouch>, with _: UIEvent) {
                state = state == .began || state == .changed ? .cancelled : .failed
            }

            override func reset() {
                super.reset()
                timers.forEach { $0.invalidate() }
                timers = []
                if isLifted, !isCarried {
                    onSettle?()
                }
                isLifted = false
                isCarried = false
                translation = .zero
            }

            private func schedule(after delay: TimeInterval, _ selector: Selector) {
                timers.append(Timer.scheduledTimer(timeInterval: delay, target: self, selector: selector, userInfo: nil, repeats: false))
            }
        }
    }
#endif

#if targetEnvironment(macCatalyst)
    /// A mouse wheel only scrolls vertically, and a horizontal scroll view
    /// ignores it — with a plain mouse the strip's hidden chips were out of
    /// reach. Placed inside the scroller's content, this finds the
    /// `UIScrollView` SwiftUI built around it and turns a wheel's vertical
    /// steps into horizontal travel, as an AppKit tab bar does. Trackpads
    /// scroll continuously, in both axes, and are left to the scroll view.
    private struct WheelScrollsHorizontally: UIViewRepresentable {
        func makeUIView(context _: Context) -> WheelView {
            WheelView()
        }

        func updateUIView(_: WheelView, context _: Context) {}

        final class WheelView: UIView, UIGestureRecognizerDelegate {
            private weak var scrollView: UIScrollView?
            private lazy var wheel: UIPanGestureRecognizer = {
                let wheel = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
                wheel.allowedScrollTypesMask = .discrete
                // Scroll events only: a press-and-drag stays the chips'.
                wheel.allowedTouchTypes = []
                wheel.delegate = self
                return wheel
            }()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                scrollView?.removeGestureRecognizer(wheel)
                scrollView = nil
                guard window != nil else { return }
                var ancestor = superview
                while let view = ancestor, !(view is UIScrollView) {
                    ancestor = view.superview
                }
                scrollView = ancestor as? UIScrollView
                scrollView?.addGestureRecognizer(wheel)
            }

            @objc private func scrolled(_ wheel: UIPanGestureRecognizer) {
                guard let scrollView else { return }
                let step = wheel.translation(in: scrollView)
                wheel.setTranslation(.zero, in: scrollView)
                // A wheel turned down reads as travel towards the end.
                let travel = abs(step.y) > abs(step.x) ? -step.y : -step.x
                let limit = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                let x = min(limit, max(0, scrollView.contentOffset.x + travel))
                scrollView.setContentOffset(CGPoint(x: x, y: scrollView.contentOffset.y), animated: false)
            }

            func gestureRecognizer(
                _: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
            ) -> Bool {
                true
            }
        }
    }
#endif
