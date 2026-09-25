//
//  DesignSystem.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// The app's design tokens. Interface code speaks these — raw point values,
/// ad-hoc font stacks, and one-off animation curves belong here, not at call
/// sites. Each scale is deliberately small: when a new value seems needed,
/// pick the nearest step instead of adding one.
enum DS {
    /// Spacing scale, for paddings and stack spacing alike.
    enum Padding {
        /// 4 — hairline gaps: badge insets, chip innards.
        static let xs: CGFloat = 4
        /// 8 — tight: icon-to-label, bar interiors.
        static let s: CGFloat = 8
        /// 12 — control padding: row insets, cluster gaps.
        static let m: CGFloat = 12
        /// 16 — container padding: bars, cards, grids.
        static let l: CGFloat = 16
        /// 24 — breathing room: empty states, hero layouts.
        static let xl: CGFloat = 24
    }

    /// Corner radii. Continuous curvature at the call site.
    enum Radius {
        /// 6 — small accents: swatches, thumbnails.
        static let s: CGFloat = 6
        /// 12 — controls: buttons, rows, icon wells.
        static let m: CGFloat = 12
        /// 16 — containers: cards, sheets, panes.
        static let l: CGFloat = 16
    }

    /// Text roles. Each is a system text style plus a weight,
    /// resolved to a point size at the view — `.font(DS.Font.body)` goes
    /// through the `View.font(_:)` overload below — so the size can carry
    /// the interface text size preference. The base is the platform's own
    /// size for the style: on iOS that follows the system's Dynamic Type
    /// setting, on the Mac it is the Mac's fixed size, and the preference
    /// multiplies either. (Catalyst never scales a text style with the
    /// content size category, which is why this is a multiplier and not a
    /// `dynamicTypeSize` override.)
    enum Font {
        /// Section and card titles.
        case title
        /// Bar buttons and standalone control glyphs.
        case control
        /// The emphasized control: confirmations, filled buttons.
        case controlEmphasis
        /// Plain body copy.
        case body
        /// List rows, chips, and secondary copy.
        case label
        /// The selected or leading variant of `label`.
        case labelEmphasis
        /// Footers and explanatory copy.
        case detail
        /// Timestamps, counts, subtitles.
        case caption
        /// Tiny controls that must hold their own: badges, close glyphs.
        case captionEmphasis
        /// Large symbol glyphs sitting alone in a row or card.
        case symbol
        /// The one oversized symbol of an empty state.
        case heroSymbol
        /// The mock prompt of an empty terminal: oversized and monospaced.
        case heroPrompt
        /// A line of a file drawn as code: a log entry, a configuration.
        case code
        /// The metadata under a line of code: a timestamp, a tag.
        case codeCaption

        /// The text style whose platform size is the base.
        var style: UIFont.TextStyle {
            switch self {
            case .title: .headline
            case .control, .controlEmphasis, .body: .body
            case .label, .labelEmphasis: .subheadline
            case .detail, .code: .footnote
            case .caption, .captionEmphasis: .caption1
            case .codeCaption: .caption2
            case .symbol: .title3
            case .heroSymbol, .heroPrompt: .largeTitle
            }
        }

        var weight: SwiftUI.Font.Weight {
            switch self {
            case .title, .controlEmphasis, .labelEmphasis, .captionEmphasis: .semibold
            case .control: .medium
            case .heroSymbol: .light
            default: .regular
            }
        }

        var design: SwiftUI.Font.Design {
            switch self {
            case .heroPrompt, .code, .codeCaption: .monospaced
            default: .default
            }
        }

        /// The role at `scale`, sized for `category` — the system's Dynamic
        /// Type setting on iOS, ignored by the Mac, where the base is fixed.
        func resolved(scale: CGFloat, category: UIContentSizeCategory) -> SwiftUI.Font {
            let base: CGFloat = switch self {
            case .heroSymbol: 52
            case .heroPrompt: 34
            default:
                UIFont.preferredFont(
                    forTextStyle: style,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: category),
                ).pointSize
            }
            return .system(size: base * scale, weight: weight, design: design)
        }
    }

    /// Motion. One spring family — no linear or eased curves, so every
    /// movement decelerates the same way.
    enum Motion {
        /// The default for state changes the eye should glide through.
        static let smooth = Animation.spring(response: 0.45, dampingFraction: 1.0)
        /// Quick flips: press feedback, drag-state highlights.
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
        /// Structural changes: tabs appearing and leaving, panes moving.
        /// A whisper of overshoot keeps insertions lively.
        static let structure = Animation.spring(response: 0.45, dampingFraction: 0.88)
    }
}

extension View {
    /// Applies a design-system text role at the interface text size in the
    /// environment. The overload every `.font(DS.Font.…)` call resolves to.
    func font(_ role: DS.Font) -> some View {
        modifier(DSFontModifier(role: role))
    }
}

private struct DSFontModifier: ViewModifier {
    let role: DS.Font
    @Environment(\.interfaceTextScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.font(role.resolved(scale: scale, category: Self.category(for: typeSize)))
    }

    /// The UIKit category for a SwiftUI size; the system offers only the
    /// other direction.
    private static func category(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
