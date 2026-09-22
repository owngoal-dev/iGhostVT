//
//  AboutSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// Version, the licenses, and the way into Advanced. Advanced sits here, at
/// the end, and not among the everyday sections: the shell path, the Mac
/// helper, and the keystroke log are settings most people never need, and
/// the ones who do will look past Version.
struct AboutSettingsSection: View {
    var body: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionDescription)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Version")
            .accessibilityValue(Self.versionDescription)
            NavigationLink {
                LicensesView()
            } label: {
                Text("Licenses")
            }
            NavigationLink {
                AdvancedSettingsView()
            } label: {
                Text("Advanced")
            }
        } header: {
            Text("About")
                .font(DS.Font.caption)
        }
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
