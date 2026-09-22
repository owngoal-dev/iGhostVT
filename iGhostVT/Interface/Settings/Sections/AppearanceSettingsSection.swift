//
//  AppearanceSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The two theme slots, light and dark; each opens the catalog list.
struct AppearanceSettingsSection: View {
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        Section {
            NavigationLink {
                ThemeListView(slot: .light)
            } label: {
                SettingsValueRow(
                    title: "Light Theme",
                    icon: "sun.max.fill",
                    value: theme.selection.lightName ?? Self.defaultLabel(AppTheme.defaultLightName)
                )
            }
            .accessibilityLabel("Light Theme")
            .accessibilityValue(theme.selection.lightName ?? Self.defaultLabel(AppTheme.defaultLightName))
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                SettingsValueRow(
                    title: "Dark Theme",
                    icon: "moon.fill",
                    value: theme.selection.darkName ?? Self.defaultLabel(AppTheme.defaultDarkName)
                )
            }
            .accessibilityLabel("Dark Theme")
            .accessibilityValue(theme.selection.darkName ?? Self.defaultLabel(AppTheme.defaultDarkName))
        } header: {
            Text("Appearance")
                .font(DS.Font.caption)
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
                .font(DS.Font.detail)
        }
    }

    /// Theme names are catalog data, so only the marker gets translated.
    private static func defaultLabel(_ name: String) -> String {
        String(
            format: NSLocalizedString("%@ (Default)", comment: "Theme name plus the default marker"),
            name
        )
    }
}
