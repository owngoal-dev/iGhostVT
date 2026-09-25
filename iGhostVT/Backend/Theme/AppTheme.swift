//
//  AppTheme.swift
//  iGhostVT
//

import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// The one owner of the terminal theme preference. Persists a light and a
/// dark selection from the Ghostty theme catalog, derives the terminal theme
/// and the chrome colors from them, and is observed by every view that
/// paints chrome — so the whole window (including safe areas) follows the
/// terminal's background.
@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    struct Selection: Equatable {
        var lightName: String?
        var darkName: String?
    }

    @Published var selection: Selection {
        didSet {
            UserDefaults.standard.set(selection.lightName, forKey: Self.lightKey)
            UserDefaults.standard.set(selection.darkName, forKey: Self.darkKey)
        }
    }

    private static let lightKey = "Theme.light"
    private static let darkKey = "Theme.dark"

    /// The catalog themes a fresh install runs — Apple's own terminal
    /// colours, so the app looks like the Mac's Terminal until someone picks
    /// otherwise. Named here, resolved from the catalog like any selection.
    static let defaultLightName = "Apple System Colors Light"
    static let defaultDarkName = "Apple System Colors"

    /// Those themes' backgrounds, for the moment the catalog has no answer.
    private static let defaultLightBackground = "FEFFFF"
    private static let defaultDarkBackground = "1E1E1E"
    private static let defaultLightForeground = "000000"
    private static let defaultDarkForeground = "FFFFFF"

    private init() {
        selection = Selection(
            lightName: UserDefaults.standard.string(forKey: Self.lightKey),
            darkName: UserDefaults.standard.string(forKey: Self.darkKey),
        )
    }

    private var lightDefinition: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: selection.lightName ?? Self.defaultLightName)
    }

    private var darkDefinition: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: selection.darkName ?? Self.defaultDarkName)
    }

    var terminalTheme: TerminalTheme {
        TerminalTheme(
            light: lightDefinition?.toTerminalConfiguration() ?? .alabaster,
            dark: darkDefinition?.toTerminalConfiguration() ?? .afterglow,
        )
    }

    func background(for scheme: ColorScheme) -> Color {
        let hex = scheme == .dark
            ? darkDefinition?.background ?? Self.defaultDarkBackground
            : lightDefinition?.background ?? Self.defaultLightBackground
        return Color(hex: hex)
    }

    /// The theme's text colour — what an empty pane writes in, so the
    /// placeholder reads on any background the theme paints, not only the
    /// one the system scheme would have chosen.
    func foreground(for scheme: ColorScheme) -> Color {
        let hex = scheme == .dark
            ? darkDefinition?.foreground ?? Self.defaultDarkForeground
            : lightDefinition?.foreground ?? Self.defaultLightForeground
        return Color(hex: hex)
    }

    func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
        )
    }
}
