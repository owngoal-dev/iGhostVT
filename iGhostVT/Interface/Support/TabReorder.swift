//
//  TabReorder.swift
//  iGhostVT
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Drag-to-reorder for the tab list, shared by the sidebar's rows and the
/// strip's chips. The row under the pointer takes the dragged tab's slot as
/// the drag passes over it (`dropEntered`, re-checked from `dropUpdated` —
/// a reorder slides rows under a pointer that never crossed their edge, and
/// the enter event alone missed those), so the list reorders live and the
/// drop itself only ends the gesture.
///
/// Built on `onDrag`/`onDrop` rather than `List.onMove` because neither
/// presentation is a `List`, and rather than `draggable`/`dropDestination`
/// because those are iOS 16. iPad and the Mac only: a drag needs a pointer
/// or a lift, and on the phone a long press on a tab is its context menu.
enum TabReorder {
    /// The drag item's own type, visible to this process alone. A tab
    /// dragged over the terminal must not paste as text, and a type that
    /// conforms to nothing is what `TerminalDropDelegate` refuses. It is
    /// declared in the app's Info.plist (`UTExportedTypeDeclarations`, with
    /// an empty conformance list) because `exportedAs` promises exactly
    /// that, and logs a complaint at first use when the bundle does not.
    static let itemType = UTType(exportedAs: "wiki.qaq.ighostvt.tab")

    /// Main-actor because `UIDevice.current` is; every reader is a view
    /// modifier, which already runs there.
    @MainActor
    static var isSupported: Bool {
        #if targetEnvironment(macCatalyst)
            return true
        #else
            return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    /// The token a drag carries. Reordering reads the tab from
    /// `DraggedTab` instead — `dropEntered` is synchronous and an item
    /// provider only loads asynchronously — so the payload is an id for
    /// form's sake, and the drag's identity is what it registers as: the
    /// item type, and a second type naming the tab (`identityType`).
    /// `DraggedTab` is per window and keeps a cancelled drag's tab, and a
    /// drag from another window of the app passes `validateDrop` all the
    /// same, so a slot has to tell whether the pointer is carrying the tab
    /// it holds — and the registered types are the one thing a drop
    /// delegate can read synchronously that reaches it on every platform.
    /// On the Mac a drag crosses the AppKit pasteboard even within the
    /// process, and what comes out the other side is a new provider with
    /// the pasteboard's types and nothing else: `suggestedName` was tried
    /// for this and arrived nil, so no slot ever moved.
    static func itemProvider(for tab: TerminalTab) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(tab.id.uuidString.utf8)
        for type in [itemType.identifier, identityType(for: tab)] {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(payload, nil)
                return nil
            }
        }
        return provider
    }

    /// Whether the drag under the pointer is the one that lifted `tab`.
    static func drag(_ info: DropInfo, carries tab: TerminalTab) -> Bool {
        info.itemProviders(for: [itemType]).contains { provider in
            provider.registeredTypeIdentifiers.contains(identityType(for: tab))
        }
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

/// The tab a drag started from, held by the list that shows it. One drag
/// at a time per list is all the system allows, so one slot suffices.
@MainActor
final class DraggedTab: ObservableObject {
    /// Not published: the views read it only from drop callbacks, and a
    /// redraw of every row at each `dropEntered` would fight the move
    /// animation.
    var tab: TerminalTab?

    /// When the last live reorder happened. `dropUpdated` fires many times
    /// a second, and a move mid-animation can land the pointer back in the
    /// slot it just left — re-moving only after a beat lets the previous
    /// move settle instead of oscillating.
    var lastSlotChange = Date.distantPast
}

/// The slot's outline: the strip's capsule or the sidebar's rounded card.
/// One shape serves as the drag preview's clip, the hairline's path, and
/// the corner mask `contentShape(.dragPreview, …)` puts on the lift — the
/// system's default lift is the view's rectangular snapshot, whose sharp
/// corners over the terminal read as a glitch.
struct TabSlotShape: InsettableShape {
    let style: TabDragPreview.Style
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch style {
        case .chip:
            return Capsule().path(in: rect)
        case .row:
            return RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).path(in: rect)
        }
    }

    func inset(by amount: CGFloat) -> TabSlotShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// What travels under the finger. The system's default is a snapshot of
/// the source view, and a chip or row that is not the active one has no
/// background of its own — the snapshot came up as a blank grey slab. So
/// the preview is drawn on purpose: the tab's name on a card that
/// is *solid to its edge* — the background colour fills the whole frame
/// and the slot's shape clips it, so no corner of it is transparent and
/// nothing behind the drag shows through — sized to the source. No accent
/// anywhere in it: the lifted card is neutral whichever tab is active.
///
/// Plain values, not the tab: the closure captures what the tab says at
/// the moment the drag begins, which is all a snapshot needs — the
/// preview is rendered in a detached hosting where an observed object's
/// updates have nowhere to land, and rendering through one there came up
/// as an empty card.
struct TabDragPreview: View {
    enum Style {
        /// The strip's capsule: one line, the chip's height.
        case chip
        /// The sidebar's card: title over the secondary line.
        case row
    }

    let title: String
    let subtitle: String
    let style: Style
    let width: CGFloat

    init(tab: TerminalTab, style: Style, width: CGFloat) {
        title = tab.displayTitle
        subtitle = tab.secondaryTitle
        self.style = style
        self.width = width
    }

    var body: some View {
        content
            .foregroundColor(.primary)
            .background(Color(uiColor: .systemBackground))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var shape: TabSlotShape {
        TabSlotShape(style: style)
    }

    /// The preview, rasterized up front. Handing SwiftUI the view itself
    /// through `onDrag(_:preview:)` produced an empty card — the detached
    /// hosting the system renders that closure in drew the background, the
    /// mask and the hairline but none of the glyphs — so the card is drawn
    /// into an image through a hosting controller of our own, at drag
    /// start, and the drag carries the image.
    @MainActor
    static func rendered(for tab: TerminalTab, style: Style, width: CGFloat) -> Image {
        let host = UIHostingController(rootView: TabDragPreview(tab: tab, style: style, width: width))
        host.view.backgroundColor = .clear
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        return Image(uiImage: image)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .chip:
            HStack(spacing: DS.Padding.xs) {
                Text(title)
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Padding.m)
            .frame(width: width, height: 32)
        case .row:
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.labelEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.s)
            .frame(width: width)
        }
    }
}

extension View {
    /// Makes this presentation of `tab` a drag source and a drop slot.
    /// Applied outside the context menu, so the lift that opens the menu
    /// is also the one that starts the drag. The `dragPreview` and
    /// `contextMenuPreview` content shapes mask both lifts to the slot's
    /// own outline — without them the system lifts a sharp-cornered
    /// rectangle of whatever happened to be behind the row.
    @ViewBuilder
    func tabReorderable(
        _ tab: TerminalTab,
        in tabManager: TabManager,
        dragged: DraggedTab,
        preview: TabDragPreview.Style,
        width: CGFloat,
    ) -> some View {
        if TabReorder.isSupported {
            contentShape([.dragPreview, .contextMenuPreview], TabSlotShape(style: preview))
                .onDrag {
                    dragged.tab = tab
                    return TabReorder.itemProvider(for: tab)
                } preview: {
                    TabDragPreview.rendered(for: tab, style: preview, width: width)
                }
                .onDrop(
                    of: [TabReorder.itemType],
                    delegate: TabReorderSlotDelegate(tab: tab, tabManager: tabManager, dragged: dragged),
                )
        } else {
            self
        }
    }

    /// The list's own drop: a release over its padding, or over a control
    /// that is not a tab, still ends the drag where the tab already sits
    /// instead of springing the preview back to where it started.
    @ViewBuilder
    func tabReorderContainer(dragged: DraggedTab) -> some View {
        if TabReorder.isSupported {
            onDrop(of: [TabReorder.itemType], delegate: TabReorderEndDelegate(dragged: dragged))
        } else {
            self
        }
    }
}

private struct TabReorderSlotDelegate: DropDelegate {
    let tab: TerminalTab
    let tabManager: TabManager
    let dragged: DraggedTab

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    func dropEntered(info: DropInfo) {
        moveDraggedTabHere(info, force: true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // The catch-up path: when a move slides this slot under a pointer
        // that never crossed its edge, no `dropEntered` fires — the update
        // stream is what still arrives, so the reorder keeps following the
        // finger instead of stopping after its first move.
        moveDraggedTabHere(info, force: false)
        return DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragged.tab = nil
        return true
    }

    /// Puts the dragged tab in this slot. An entered slot moves at once;
    /// the update stream only re-moves after the last move has had a beat
    /// to settle, so a pointer sitting on a mid-animation boundary does
    /// not bounce the two tabs back and forth.
    private func moveDraggedTabHere(_ info: DropInfo, force: Bool) {
        guard let moving = dragged.tab, moving.id != tab.id, TabReorder.drag(info, carries: moving) else { return }
        let now = Date()
        guard force || now.timeIntervalSince(dragged.lastSlotChange) > 0.25 else { return }
        dragged.lastSlotChange = now
        tabManager.moveTab(moving, toSlotOf: tab)
    }
}

private struct TabReorderEndDelegate: DropDelegate {
    let dragged: DraggedTab

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragged.tab = nil
        return true
    }
}
