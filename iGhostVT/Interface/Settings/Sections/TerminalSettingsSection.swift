//
//  TerminalSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What a terminal starts with and what the app keeps of it: the size a
/// new surface opens at, whether a launch opens one, and the new-tab
/// menu's remembered directories. The
/// interface's own text size is the system's here — Dynamic Type — and
/// only the Mac, where Catalyst ignores it, has a stepper for it.
struct TerminalSettingsSection: View {
    /// Read by `TerminalTab` when a surface is made; open tabs keep theirs.
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    @ObservedObject private var recents = RecentDirectoryStore.shared

    var body: some View {
        Section {
            Stepper(value: $terminalFontSize, in: TerminalFontSize.range) {
                SettingsValueRow(title: "Text Size", value: fontSizeDescription)
            }
            .accessibilityLabel("Text Size")
            .accessibilityValue(fontSizeDescription)
            Toggle("New Session at Launch", isOn: $opensNewSession)
            Toggle("Remember Directories", isOn: $recents.isEnabled)
        } header: {
            Text("Terminal")
                .font(DS.Font.caption)
        } footer: {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text(
                    """
                    New terminals open at this text size; a tab that is already \
                    open keeps the size it was zoomed to.
                    """,
                )
                Text(
                    """
                    New Session at Launch opens a session when the app starts \
                    with nothing to resume. With it off, the app opens with no tabs.
                    """,
                )
                Text(
                    """
                    Remember Directories lets New Tab offer the directories your \
                    terminals have been in before. With it off, that list is \
                    forgotten and nothing is added to it.
                    """,
                )
            }
            .font(DS.Font.detail)
        }
    }

    private var fontSizeDescription: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld pt", comment: "A font size in points"),
            terminalFontSize,
        )
    }
}
