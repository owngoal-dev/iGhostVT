//
//  ShortcutsSettingsView.swift
//  iGhostVT
//

import SwiftUI

/// Settings ▸ Keyboard ▸ Shortcuts: every shortcut of the app with its own
/// switch, sectioned the way the menu groups them. Off, the key reaches the
/// program in the terminal and leaves the menu; nothing is rebound.
struct ShortcutsSettingsView: View {
    /// Flipped on every change so the rows re-read UserDefaults.
    @State private var revision = 0

    var body: some View {
        Form {
            ForEach(ShortcutGroup.allCases, id: \.self) { group in
                Section {
                    ForEach(KeyShortcuts.listed(in: group), id: \.id) { shortcut in
                        row(shortcut)
                    }
                } header: {
                    Text(group.title)
                        .font(DS.Font.caption)
                }
            }
            Section {} footer: {
                Text("A shortcut that is off hands its key to the program running in the terminal. Escape always reaches the terminal.")
                    .font(DS.Font.detail)
            }
            SettingsFormSpacer()
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ shortcut: KeyShortcut) -> some View {
        Toggle(isOn: Binding(
            get: { _ = revision; return shortcut.isEnabled },
            set: { enabled in
                KeyShortcuts.setEnabled(enabled, for: shortcut)
                revision += 1
            },
        )) {
            HStack {
                Text(shortcut.title)
                Spacer()
                Text(shortcut.display)
                    .font(DS.Font.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing, DS.Padding.s)
            }
        }
    }
}
