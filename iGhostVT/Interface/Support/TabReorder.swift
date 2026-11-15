//
//  TabReorder.swift
//  iGhostVT
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Drag-to-reorder for the sidebar's rows (the top bar's strip reorders
/// with a gesture of its own, `TabStripBar`, so that a plain drag along it
/// still scrolls it or moves the Mac window). The row under the pointer takes the dragged tab's slot
/// as the drag passes over it (`dropEntered`, re-checked from
/// `dropUpdated` — a reorder slides rows under a pointer that never
/// crossed their edge, and the enter event alone missed those), so the
/// list reorders live and the drop itself only ends the gesture.
///
/// Built on `onDrag`/`onDrop` rather than `List.onMove` because neither
/// presentation is a `List`, and rather than `draggable`/`dropDestination`
/// because those are iOS 16. The sidebar's rows reorder wherever there is
/// a sidebar — a regular-width window, which a phone has too: the inner
/// display of a foldable, a large phone held sideways. The switcher's
/// cards reorder on the phone as well, where the long press that opens a
/// card's menu lifts it, and moving the finger then carries it.
enum TabReorder {
    /// The drag item's own type, visible to this process alone. A tab
    /// dragged over the terminal must not paste as text, and a type that
    /// conforms to nothing is what `TerminalDropDelegate` refuses. It is
    /// declared in the app's Info.plist (`UTExportedTypeDeclarations`, with
    /// an empty conformance list) because `exportedAs` promises exactly
    /// that, and logs a complaint at first use when the bundle does not.
    static let itemType = UTType(exportedAs: "wiki.qaq.ighostvt.tab")

    /// The token a drag carries. `dropEntered` is synchronous and an item
    /// provider only loads asynchronously, so the payload is an id for
    /// form's sake, and the drag's identity is what it registers as: the
    /// item type, and a second type naming the tab (`identityType`). The
    /// registered types are the one thing a drop delegate can read
    /// synchronously that reaches it on every platform. On the Mac a drag
    /// crosses the AppKit pasteboard even within the process, and what
    /// comes out the other side is a new provider with the pasteboard's
    /// types and nothing else: `suggestedName` was tried for this and
    /// arrived nil, so no slot ever moved.
    ///
    /// A tab that can move to a window of its own also carries the move's
    /// `NSUserActivity` (`TabWindowMove`), visible to the system: dropped
    /// beside the window rather than on a slot, the drag becomes a new
    /// window holding the tab. A drop on a slot still only reorders.
    @MainActor
    static func itemProvider(for tab: TerminalTab, in tabManager: TabManager) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(tab.id.uuidString.utf8)
        for type in [itemType.identifier, identityType(for: tab)] {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(payload, nil)
                return nil
            }
        }
        if let activity = TabWindowMove.activity(for: tab, in: tabManager) {
            provider.registerObject(activity, visibility: .all)
        }
        return provider
    }

    /// The tab the drag under the pointer lifted, read from the drag
    /// itself. Not from a "dragged tab" the source stashes in `onDrag`: on
    /// the Mac that closure runs when SwiftUI feels like it — again for
    /// rows a reorder slid, sometimes not at all for a fresh lift — so a
    /// stash named the wrong tab, or none on a fast drag. A drag from
    /// another window names a tab this list does not hold, and is nil.
    static func tab(draggedIn info: DropInfo, from tabs: [TerminalTab]) -> TerminalTab? {
        let prefix = "\(itemType.identifier)."
        for provider in info.itemProviders(for: [itemType]) {
            for type in provider.registeredTypeIdentifiers where type.hasPrefix(prefix) {
                guard let id = UUID(uuidString: String(type.dropFirst(prefix.count))) else { continue }
                return tabs.first { $0.id == id }
            }
        }
        return nil
    }

    /// The type identifier that names one tab's drag: the item type with
    /// the tab's id appended. Undeclared, so it reads back as a dynamic
    /// type — a pasteboard carries any string as a type, and
    /// `TerminalDropDelegate` skips dynamic ones — and registered by its
    /// string, which asks the bundle for nothing.
    private static func identityType(for tab: TerminalTab) -> String {
        "\(itemType.identifier).\(tab.id.uuidString)"
    }
}

/// A reorder's pacing, held by the list that shows the tabs. One drag at
/// a time per list is all the system allows, so one record suffices. Not
/// published: only drop callbacks read it, and a redraw of every row at
/// each `dropEntered` would fight the move animation.
@MainActor
final class TabReorderPacing: ObservableObject {
    /// When the last live reorder happened. `dropUpdated` fires many times
    /// a second, and a move mid-animation can land the pointer back in the
    /// slot it just left — re-moving only after a beat lets the previous
    /// move settle instead of oscillating.
    var lastSlotChange = Date.distantPast
}

/// The slot's outline: the sidebar's rounded card. One shape serves as the drag preview's clip, the hairline's path, and
/// the corner mask `contentShape(.dragPreview, …)` puts on the lift — the
/// system's default lift is the view's rectangular snapshot, whose sharp
/// corners over the terminal read as a glitch.
struct TabSlotShape: InsettableShape {
    let style: TabDragPreview.Style
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch style {
        case .row:
            return RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).path(in: rect)
        case .card:
            return RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).path(in: rect)
        }
    }

    func inset(by amount: CGFloat) -> TabSlotShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// What travels under the finger: the slot itself, lifted. Drawn previews
/// were tried twice and both came up as an empty card on iPadOS 26 — the
/// view handed to `onDrag(_:preview:)`, and an image rasterized from it
/// through an offscreen hosting controller: SwiftUI's text never reaches a
/// layer tree that is not on screen, so the card carried the background
/// and the hairline and no title. The lift is a snapshot of the on-screen
/// slot, text and all, masked to the slot's shape (`TabSlotShape`). A
/// sidebar row paints the theme's background under itself
/// (`TabSlotBackground`) — invisible in place, since the sidebar shows that
/// same colour, and what keeps the lifted card solid to its edge in a dark
/// theme.
enum TabDragPreview {
    enum Style {
        /// The sidebar's card: title over the secondary line.
        case row
        /// The switcher's card, which paints its own background.
        case card
    }
}

/// The theme's background under a sidebar row, for the lift to snapshot.
private struct TabSlotBackground: ViewModifier {
    let style: TabDragPreview.Style
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .row:
            content.background(
                WindowTranslucency.isEnabled ? Color.clear : theme.background(for: colorScheme),
                in: TabSlotShape(style: style),
            )
        case .card:
            content
        }
    }
}

extension View {
    /// Makes this presentation of `tab` a drag source and a drop slot.
    /// Paired with the context menu by `tabMenuAndReorder`, so the lift
    /// that opens the menu is also the one that starts the drag. The `dragPreview` and
    /// `contextMenuPreview` content shapes mask both lifts to the slot's
    /// own outline — without them the system lifts a sharp-cornered
    /// rectangle of whatever happened to be behind the row.
    func tabReorderable(
        _ tab: TerminalTab,
        in tabManager: TabManager,
        pacing: TabReorderPacing,
        preview: TabDragPreview.Style,
    ) -> some View {
        modifier(TabSlotBackground(style: preview))
            .contentShape([.dragPreview, .contextMenuPreview], TabSlotShape(style: preview))
            .onDrag {
                TabReorder.itemProvider(for: tab, in: tabManager)
            }
            .onDrop(
                of: [TabReorder.itemType] + TabDragHover.types,
                delegate: TabReorderSlotDelegate(tab: tab, tabManager: tabManager, pacing: pacing),
            )
    }

    /// The tab's context menu and its drag, in the order this system
    /// needs them. Each order breaks the other system: on iOS 27 a drag
    /// source outside the menu never got the lift, and the row stayed in
    /// its slot; on iOS 26 a drag source inside the menu lost the press to
    /// the scroll view, and the list scrolled instead. The Mac keeps the
    /// order it was built and tested with.
    @ViewBuilder
    func tabMenuAndReorder(
        _ tab: TerminalTab,
        in tabManager: TabManager,
        pacing: TabReorderPacing,
        preview: TabDragPreview.Style,
        window: UIWindow?,
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            contextMenu { TabContextMenu(tab: tab, tabManager: tabManager, window: window) }
                .tabReorderable(tab, in: tabManager, pacing: pacing, preview: preview)
        #else
            if #available(iOS 27, *) {
                tabReorderable(tab, in: tabManager, pacing: pacing, preview: preview)
                    .contextMenu { TabContextMenu(tab: tab, tabManager: tabManager, window: window) }
            } else {
                contextMenu { TabContextMenu(tab: tab, tabManager: tabManager, window: window) }
                    .tabReorderable(tab, in: tabManager, pacing: pacing, preview: preview)
            }
        #endif
    }

    /// The list's own drop: a release over its padding, or over a control
    /// that is not a tab, still ends the drag where the tab already sits
    /// instead of springing the preview back to where it started.
    func tabReorderContainer() -> some View {
        onDrop(of: [TabReorder.itemType], delegate: TabReorderEndDelegate())
    }
}

/// A tab's own drag reorders; any other drag resting on the slot brings
/// its tab forward (`TabDragHover`) and is not taken here. One delegate
/// for both, since a second `onDrop` on the same row would compete with
/// this one for the drag.
private struct TabReorderSlotDelegate: DropDelegate {
    let tab: TerminalTab
    let tabManager: TabManager
    let pacing: TabReorderPacing

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType]) || TabDragHover.answers(info)
    }

    func dropEntered(info: DropInfo) {
        guard isReorder(info) else { return TabDragHover.enter(tab, in: tabManager) }
        moveDraggedTabHere(info, force: true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isReorder(info) else { return DropProposal(operation: .cancel) }
        // The catch-up path: when a move slides this slot under a pointer
        // that never crossed its edge, no `dropEntered` fires — the update
        // stream is what still arrives, so the reorder keeps following the
        // finger instead of stopping after its first move.
        moveDraggedTabHere(info, force: false)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        TabDragHover.leave(tab)
    }

    func performDrop(info: DropInfo) -> Bool {
        TabDragHover.leave(tab)
        return isReorder(info)
    }

    private func isReorder(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    /// Puts the dragged tab in this slot. An entered slot moves at once;
    /// the update stream only re-moves after the last move has had a beat
    /// to settle, so a pointer sitting on a mid-animation boundary does
    /// not bounce the two tabs back and forth.
    private func moveDraggedTabHere(_ info: DropInfo, force: Bool) {
        guard let moving = TabReorder.tab(draggedIn: info, from: tabManager.tabs), moving.id != tab.id else { return }
        let now = Date()
        guard force || now.timeIntervalSince(pacing.lastSlotChange) > 0.25 else { return }
        pacing.lastSlotChange = now
        tabManager.moveTab(moving, toSlotOf: tab)
    }
}

private struct TabReorderEndDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        true
    }
}
