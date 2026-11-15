import SwiftUI
import UIKit

extension View {
    /// Liquid Glass on iOS 26+, material capsule/shape fallback below.
    ///
    /// `geometryGroup()` where available: the glass/material layer renders
    /// out-of-band from SwiftUI's geometry interpolation, so a layout shift
    /// (the sidebar opening) moves the label first and drags the background
    /// a beat behind it. Grouping resolves the subtree's geometry in one
    /// transaction so both travel together. iOS 15/16 have no equivalent.
    @ViewBuilder
    func barGlass(in shape: some Shape, interactive: Bool = true, floatsOverContent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if WindowTranslucency.isEnabled, !floatsOverContent {
                background(Color.primary.opacity(0.08), in: shape)
                    .geometryGroup()
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .geometryGroup()
            }
        } else if #available(iOS 17.0, *) {
            background(.ultraThinMaterial, in: shape)
                .geometryGroup()
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Glass inside this view fades in and out on its own when it is
    /// inserted or removed, instead of the container's default of melting
    /// into the glass beside it. For a bar that swaps one set of controls
    /// for another: morphing between them drew a capsule shrinking into a
    /// circle and blobs splitting and merging on the way.
    @ViewBuilder
    func glassMaterializes() -> some View {
        if #available(iOS 26.0, *) {
            glassEffectTransition(.materialize)
        } else {
            self
        }
    }
}

extension View {
    /// The card treatment — the alert, the Mac's settings panel: Liquid
    /// Glass on iOS 26+, the material card it replaces below. The content is
    /// clipped to the shape either way, so a scrolling pane inside stays
    /// within the corners.
    @ViewBuilder
    func cardGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            clipShape(shape)
                .background(.regularMaterial)
                .background(Color(UIColor.systemBackground).opacity(0.5))
                .clipShape(shape)
        }
    }
}

/// `GlassEffectContainer` when available so sibling glass elements share one
/// sampling region; transparent grouping otherwise.
struct GlassBarContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}
