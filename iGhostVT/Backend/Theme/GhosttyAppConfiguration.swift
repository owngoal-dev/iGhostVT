import Foundation
import GhosttyTerminal

/// Runtime Ghostty config compiled into the generated overlay.
///
/// On Mac, CJK ranges are pinned to PingFang SC so CoreText never picks a
/// face at first sight (ghostty#9410). That is `font-codepoint-map` only —
/// a bare `font-family = PingFang SC` becomes the primary face when the
/// overlay has no earlier family, and PingFang is proportional, so every
/// cell is stretched (ghostty#12694). iOS already falls back to PingFang
/// stably; it does not need the map.
///
/// The font size is written here as well as into the surface options. The
/// library's base config carries its own `font-size` (10 on every iOS-family
/// build, Catalyst included), and the surface option only overrides it at
/// the surface's birth: every later config reload — the colour scheme the
/// view reports on mount, a theme change — reapplies the *file* to the
/// surface, and a file without the preference reset the first terminal to
/// the library's size. A later line wins in ghostty, so this one does.
enum GhosttyAppConfiguration {
    /// Called before any terminal is created and on explicit quit. Startup
    /// also catches files left by a force-quit, where iOS sends no callback.
    @MainActor
    static func removeTemporaryFiles() {
        do {
            try FileManager.default.removeItem(at: TerminalController.managedConfigDirectory)
        } catch CocoaError.fileNoSuchFile {
            // A clean launch has no directory yet; the library creates it.
        } catch {
            AppLog.warning(.ghostty, "Could not remove temporary configurations: \(error)")
        }
    }

    static var terminal: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(TerminalFontSize.preferred)
            // Said outright rather than left to the default: a connected
            // terminal whose shell has yet to print (half a minute for the
            // first shell after a reboot) has only the cursor to show it
            // is alive, and a blinking one reads as waiting where a still
            // one reads as dead. A program that sets DECSCUSR still wins.
            builder.withCursorStyleBlink(true)
            // The grid rarely divides the pane exactly, and the remainder is
            // painted as padding. A program that paints its own background
            // (a TUI on the primary screen, vim) then sits in a box of the
            // theme's colour with a lip of a different one along two edges.
            // `extend` paints that lip with the nearest cell's background;
            // ghostty's own heuristic keeps it off a row with any
            // default-background cell, a prompt row, or a powerline row.
            builder.withCustom("window-padding-color", "extend")
            #if targetEnvironment(macCatalyst)
                builder.withCustom("font-codepoint-map", "U+4E00-U+9FFF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+3400-U+4DBF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+F900-U+FAFF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+3000-U+303F=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+FF00-U+FFEF=PingFang SC")
            #endif
        }
    }

    // MARK: - The user's own lines

    /// What Settings ▸ Advanced ▸ Custom Configuration holds, verbatim.
    static let customConfigurationKey = "Terminal.customConfiguration"

    static var customConfiguration: String {
        UserDefaults.standard.string(forKey: customConfigurationKey) ?? ""
    }

    /// Undoes the keyboard's smart punctuation. A text view turns `"` into
    /// curly quotes and `--` into a dash as they are typed, and ghostty
    /// reads neither as syntax — `font-family = “Menlo”` names a font
    /// whose name has quotes in it, and fails without a word.
    static func straighteningPunctuation(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
            ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("\u{2014}", "--"), ("\u{2013}", "-"),
        ]
        return replacements.reduce(text) { text, pair in
            text.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    /// The user's `key = value` lines, in order. A comment, a blank, or a
    /// line with no key is left out; the value goes through as written, so
    /// ghostty parses quotes and lists exactly as it would from its own
    /// file, and reports a bad value in its log rather than failing the
    /// surface.
    static func customEntries(in text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=")
            else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
            return (key, value)
        }
    }

    /// The theme with the user's lines appended to both appearances. The
    /// library writes the theme *after* the overlay, and a later line wins
    /// in ghostty, so this is the only place a custom `background` or
    /// `palette` is not overridden by the theme it is meant to change.
    ///
    /// `custom` is the text a tab was opened with (`TerminalTab`), so a
    /// theme change re-applies *those* lines to it rather than whatever
    /// Settings holds now — open tabs keep the configuration they were
    /// opened with, as Settings says.
    @MainActor
    static func theme(custom: String = customConfiguration) -> TerminalTheme {
        let theme = AppTheme.shared.terminalTheme
        let entries = customEntries(in: custom)
        guard !entries.isEmpty else { return theme }
        func withEntries(_ base: TerminalConfiguration) -> TerminalConfiguration {
            TerminalConfiguration(startingFrom: base) { builder in
                for entry in entries {
                    builder.withCustom(entry.key, entry.value)
                }
            }
        }
        return TerminalTheme(light: withEntries(theme.light), dark: withEntries(theme.dark))
    }

    /// The configuration file a terminal opened now would run, as ghostty
    /// reads it: the library's base, this overlay, then the theme for
    /// `colorScheme` with the user's lines — the same order the library's
    /// renderer joins them in, so what Settings shows is what a surface
    /// gets. Purely informational; the library writes the real file itself
    /// when a tab is made.
    @MainActor
    static func renderedConfig(for colorScheme: TerminalColorScheme) -> String {
        let theme = theme()
        let themeConfiguration = colorScheme == .dark ? theme.dark : theme.light
        return [
            TerminalConfiguration.default.rendered,
            terminal.rendered,
            themeConfiguration.rendered,
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n") + "\n"
    }
}
