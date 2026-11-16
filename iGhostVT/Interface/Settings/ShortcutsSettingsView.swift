//
//  ShortcutsSettingsView.swift
//  iGhostVT
//

import SwiftUI

/// Settings ▸ Keyboard ▸ Shortcuts: every shortcut of the app with its own
/// switch, sectioned the way the menu groups them. Off, the key reaches the
/// program in the terminal and leaves the menu; nothing is rebound.
///
/// On iPhone and iPad a last section holds the one key the system takes
/// from the terminal — Control-Space, to switch the keyboard language
/// (`InputSourceSwitch`). It is no shortcut of the app's, so it is not in
/// `KeyShortcuts.all`, but it reads the same way: off, the key reaches the
/// program, which the page's footer below it already says.
struct ShortcutsSettingsView: View {
    /// Flipped on every change so the rows re-read UserDefaults.
    @State private var revision = 0

    #if !targetEnvironment(macCatalyst)
        @AppStorage(InputSourceSwitch.key) private var switchesInputSource = InputSourceSwitch.defaultValue
    #endif

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
            #if !targetEnvironment(macCatalyst)
                inputSourceSection
            #endif
            Section {} footer: {
                Text("A shortcut that is off hands its key to the program running in the terminal. Escape always reaches the terminal.")
                    .font(DS.Font.detail)
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if !targetEnvironment(macCatalyst)
        private var inputSourceSection: some View {
            Section {
                Toggle(isOn: $switchesInputSource) {
                    HStack {
                        Text("Switch Keyboard Language")
                        Spacer()
                        Text("⌃" + NSLocalizedString("Space", comment: "Key name: the space bar"))
                            .foregroundColor(.secondary)
                            .padding(.trailing, DS.Padding.s)
                    }
                }
            } header: {
                Text("System")
                    .font(DS.Font.caption)
            } footer: {
                Text("With more than one keyboard language added, Control-Space switches between them.")
                    .font(DS.Font.detail)
            }
        }
    #endif

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
                    .foregroundColor(.secondary)
                    .padding(.trailing, DS.Padding.s)
            }
        }
    }
}
