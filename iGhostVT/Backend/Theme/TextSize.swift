//
//  TextSize.swift
//  iGhostVT
//

import Foundation
import SwiftUI

/// The interface's text size, kept as steps around the platform's own
/// size rather than as a size of its own. Zero is the platform default;
/// each step multiplies every `DS.Font` role by ten percent, on top of
/// whatever the system's Dynamic Type setting already did on iOS. A
/// multiplier, not a `dynamicTypeSize` override, because Catalyst never
/// scales a text style with the content size category.
enum InterfaceTextSize {
    static let key = "Interface.textSizeStep"

    /// Roughly two thirds to double the default size.
    static let steps = -4 ... 8

    static func scale(step: Int) -> CGFloat {
        pow(1.1, CGFloat(min(max(step, steps.lowerBound), steps.upperBound)))
    }
}

/// Settings ▸ Text Size: every terminal's size. A tab differs from it only
/// by its own offset (`TabFontSize`), which a pinch, ⌘+ / ⌘− or the tab's
/// menu moves and Actual Size clears; a change here moves every open tab
/// by the same step, offsets kept. Nothing but Settings writes it — a zoom
/// once stepped it too, so zooming one tab changed the size every later tab
/// opened at, and Actual Size put the tab and Settings at two sizes.
enum TerminalFontSize {
    static let key = "Terminal.fontSize"

    // The Mac a little under libghostty's own 14, which read large in the
    // iPad idiom's scaled window; the device keeps the smaller size the
    // library's default configuration renders there.
    #if targetEnvironment(macCatalyst)
        static let `default` = 12
    #else
        static let `default` = 10
    #endif

    /// The library's own zoom limits, so the stepper and the pinch agree on
    /// where the ends are.
    static let range = 4 ... 64

    /// The stored size, clamped.
    static var base: Int {
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? `default`
        return clamped(value)
    }

    /// The base as the surface configuration wants it: what the generated
    /// ghostty config says, so Ghostty's own `reset_font_size` lands on it.
    static var preferred: Float {
        Float(base)
    }

    /// A tab's size: the base moved by the tab's offset, inside `range`.
    static func size(offset: Int) -> Float {
        Float(clamped(base + offset))
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
