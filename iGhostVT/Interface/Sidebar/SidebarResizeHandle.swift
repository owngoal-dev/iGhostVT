//
//  SidebarResizeHandle.swift
//  iGhostVT
//

import SwiftUI

/// The invisible strip on the sidebar's trailing edge that resizes it: a hit
/// area wide enough to catch a finger, drawn as nothing — the hairline is
/// the affordance, as in Finder. Dragging resizes the sidebar live — the
/// terminal pane's own resize throttle absorbs the storm of grid changes.
struct SidebarResizeHandle: View {
    @Binding var width: Double

    /// Wide enough for tab titles, narrow enough to leave the terminal a
    /// usable grid in a half-width Split View window.
    static let widthRange: ClosedRange<Double> = 240 ... 420

    /// Width at the drag's start; translations apply against this so a drag
    /// that wanders past a clamp edge and back stays anchored to the finger.
    @State private var dragBaseWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // Global coordinate space: the handle rides the sidebar's
                // trailing edge, so its local space moves with every width
                // change — translations measured there oscillate against the
                // finger and the drag jitters.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        #if targetEnvironment(macCatalyst)
                            MacCursor.columnResize.set()
                        #endif
                        let base = dragBaseWidth ?? width
                        dragBaseWidth = base
                        width = (base + value.translation.width)
                            .clamped(to: Self.widthRange)
                    }
                    .onEnded { _ in
                        dragBaseWidth = nil
                    },
            )
            .modifier(ColumnResizePointer(isDragging: dragBaseWidth != nil))
            .accessibilityLabel("Resize Sidebar")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = (width + 20).clamped(to: Self.widthRange)
                case .decrement: width = (width - 20).clamped(to: Self.widthRange)
                @unknown default: break
                }
            }
    }
}

private struct ColumnResizePointer: ViewModifier {
    let isDragging: Bool
    @State private var isInside = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
            if #available(iOS 16.0, *) {
                content
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            isInside = true
                            MacCursor.columnResize.set()
                        case .ended:
                            isInside = false
                            if !isDragging {
                                MacCursor.arrow.set()
                            }
                        }
                    }
                    .onChange(of: isDragging) { dragging in
                        if !dragging, !isInside {
                            MacCursor.arrow.set()
                        }
                    }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
