//
//  KeyboardBarSettingsView.swift
//  iGhostVT
//

import SwiftUI

// The bar it edits is a software-keyboard fixture the library defines only
// off Catalyst.
#if !targetEnvironment(macCatalyst)

    /// Old-Control-Center-style editor for the keyboard accessory bar: the keys
    /// on the bar sit in one reorderable list with red remove buttons, everything
    /// else waits below behind green add buttons, and a live preview mirrors the
    /// bar's own button styling.
    struct KeyboardBarSettingsView: View {
        @ObservedObject private var store = KeyboardBarStore.shared
        @State private var showsCustomKeySheet = false
        @AppStorage(KeyboardBarStore.hidesWithHardwareKeyboardKey) private var hidesWithHardwareKeyboard = false

        var body: some View {
            List {
                previewSection
                includedSection
                moreKeysSection
                resetSection
                hardwareKeyboardSection
                SettingsFormSpacer()
            }
            // Permanently in edit mode, the way the old Control Center editor
            // was: reorder handles always visible, no Edit button to find first.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Accessory Keys")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsCustomKeySheet) {
                CustomKeySheet { symbol in
                    store.add(.symbol(symbol))
                }
            }
        }

        // MARK: - Preview

        private var previewSection: some View {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Padding.s) {
                        ForEach(store.entries) { entry in
                            KeyboardBarKeyGlyph(key: entry.key)
                        }
                    }
                    .padding(.horizontal, DS.Padding.xs)
                    .frame(minHeight: 52)
                }
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            } header: {
                Text("Preview")
                    .font(DS.Font.caption)
            } footer: {
                Text(
                    "The bar above the keyboard shows these keys in this order. Scroll sideways if they do not all fit."
                )
                .font(DS.Font.detail)
            }
        }

        // MARK: - Included keys

        private var includedSection: some View {
            Section {
                ForEach(store.entries) { entry in
                    HStack(spacing: DS.Padding.m) {
                        Button(action: { remove(entry) }) {
                            Image(systemName: "minus.circle.fill")
                                .font(DS.Font.symbol)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(entry.key.displayName)"))

                        KeyboardBarKeyGlyph(key: entry.key, size: 28)
                        Text(entry.key.displayName)
                    }
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("On the Bar")
                    .font(DS.Font.caption)
            } footer: {
                Text("Drag to reorder. Removing a standard key returns it to More Keys; dividers and custom keys are deleted.")
                    .font(DS.Font.detail)
            }
        }

        // MARK: - More keys

        private var moreKeysSection: some View {
            Section {
                ForEach(store.availableKeys, id: \.self) { key in
                    HStack(spacing: DS.Padding.m) {
                        addButton { store.add(key) }
                            .accessibilityLabel(Text("Add \(key.displayName)"))
                        KeyboardBarKeyGlyph(key: key, size: 28)
                        Text(key.displayName)
                    }
                }

                HStack(spacing: DS.Padding.m) {
                    addButton { store.add(.divider) }
                        .accessibilityLabel(Text("Add Divider"))
                    KeyboardBarKeyGlyph(key: .divider, size: 28)
                    Text("Divider")
                    Spacer()
                    Text("Multiple allowed")
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                }

                Button(action: { showsCustomKeySheet = true }) {
                    HStack(spacing: DS.Padding.m) {
                        Image(systemName: "plus.circle.fill")
                            .font(DS.Font.symbol)
                            .foregroundColor(.green)
                        Text("Add Custom Key…")
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("More Keys")
                    .font(DS.Font.caption)
            } footer: {
                Text(
                    "A custom key types the characters you enter, together with any modifier keys that are switched on."
                )
                .font(DS.Font.detail)
            }
        }

        private var resetSection: some View {
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    withAnimation { store.reset() }
                }
                .disabled(store.isDefaultArrangement)
            }
        }

        private var hardwareKeyboardSection: some View {
            Section {
                Toggle("Hide with Hardware Keyboard", isOn: $hidesWithHardwareKeyboard)
            } footer: {
                Text("The bar stays down while a hardware keyboard is connected.")
                    .font(DS.Font.detail)
            }
        }

        private func addButton(action: @escaping () -> Void) -> some View {
            Button(action: { withAnimation { action() } }) {
                Image(systemName: "plus.circle.fill")
                    .font(DS.Font.symbol)
                    .foregroundColor(.green)
            }
            .buttonStyle(.borderless)
        }

        private func remove(_ entry: KeyboardBarStore.Entry) {
            withAnimation { store.remove(entry) }
        }
    }

    /// One key rendered the way the accessory bar itself renders it: the same
    /// circular backdrop, the same SF Symbol or monospaced label, and the same
    /// small dot for a divider.
    struct KeyboardBarKeyGlyph: View {
        let key: KeyboardBarKey
        var size: CGFloat = 36

        var body: some View {
            Group {
                if key == .divider {
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 6, height: 6)
                        .frame(width: size, height: size)
                } else {
                    glyph
                        .frame(width: size, height: size)
                        .background(
                            Circle().fill(Color(uiColor: .systemGray5).opacity(0.92))
                        )
                }
            }
            .accessibilityHidden(true)
        }

        @ViewBuilder
        private var glyph: some View {
            if let systemImage = key.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundColor(.primary)
            } else if case let .symbol(symbol) = key {
                Text(symbol)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    /// Small entry sheet for a free-form key. A sheet rather than an alert
    /// because alert text fields only exist from iOS 16 and this app supports 15.
    private struct CustomKeySheet: View {
        let onAdd: (String) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var text = ""

        private static let placeholder = "|"

        private var trimmed: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var isValid: Bool {
            !trimmed.isEmpty && trimmed.count <= 3
        }

        var body: some View {
            NavigationView {
                Form {
                    Section {
                        // A literal example, not copy: the StringProtocol
                        // overload keeps it out of the string catalog.
                        TextField(Self.placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .accessibilityLabel("Custom Key")
                    } footer: {
                        Text("Up to three characters, sent exactly as typed. A single letter also works with Control.")
                            .font(DS.Font.detail)
                    }
                }
                .navigationTitle("Custom Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onAdd(trimmed)
                            dismiss()
                        }
                        .disabled(!isValid)
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

#endif
