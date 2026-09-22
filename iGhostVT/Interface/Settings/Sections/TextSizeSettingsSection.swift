//
//  TextSizeSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// One stepper per kind of text: the terminal's, a point size the surface
/// takes as it is, and the chrome's, a multiplier on every `DS.Font` role.
/// The terminal comes first — it is what people came to resize; the sheet's
/// own rows carry the roles, so the second stepper shows its effect as it
/// goes.
struct TextSizeSettingsSection: View {
    /// Read by `TerminalTab` when a surface is made; open tabs keep theirs.
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default

    /// Steps around the platform's own text size; see `InterfaceTextSize`.
    @AppStorage(InterfaceTextSize.key) private var interfaceTextStep = 0

    var body: some View {
        Section {
            Stepper(value: $terminalFontSize, in: TerminalFontSize.range) {
                SettingsValueRow(
                    title: "Terminal",
                    icon: "terminal",
                    value: String.localizedStringWithFormat(
                        NSLocalizedString("%lld pt", comment: "A font size in points"),
                        terminalFontSize
                    )
                )
            }
            .accessibilityLabel("Terminal")
            .accessibilityValue(String.localizedStringWithFormat(
                NSLocalizedString("%lld pt", comment: "A font size in points"),
                terminalFontSize
            ))
            Stepper(value: $interfaceTextStep, in: InterfaceTextSize.steps) {
                SettingsValueRow(title: "Interface", icon: "textformat.size", value: interfaceScaleDescription)
            }
            .accessibilityLabel("Interface")
            .accessibilityValue(interfaceScaleDescription)
        } header: {
            Text("Text Size")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                New terminals open at the terminal size; a tab that is already \
                open keeps the size it was zoomed to. The interface size scales \
                every label and control.
                """
            )
            .font(DS.Font.detail)
        }
    }

    /// The multiplier as a percentage; a number needs no translation.
    private var interfaceScaleDescription: String {
        let percent = Int((InterfaceTextSize.scale(step: interfaceTextStep) * 100).rounded())
        return "\(percent)%"
    }
}
