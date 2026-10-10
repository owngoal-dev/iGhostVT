//
//  KeyboardBarSettingsView.swift
//  iGhostVT
//

import SwiftUI
import UIKit

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
        @State private var editedEntry: KeyboardBarStore.Entry?
        @AppStorage(KeyboardBarStore.hidesWithHardwareKeyboardKey) private var hidesWithHardwareKeyboard = false

        var body: some View {
            List {
                previewSection
                includedSection
                moreKeysSection
                resetSection
                hardwareKeyboardSection
            }
            // Permanently in edit mode, the way the old Control Center editor
            // was: reorder handles always visible, no Edit button to find first.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Accessory Keys")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsCustomKeySheet) {
                CustomKeySheet(editing: nil) { key in
                    store.add(key)
                }
            }
            .sheet(item: $editedEntry) { entry in
                CustomKeySheet(editing: entry.key) { key in
                    store.replace(entry, with: key)
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
                    "The bar above the keyboard shows these keys in this order. Scroll sideways if they do not all fit.",
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

                        if entry.key.sentText != nil {
                            // A symbol or custom key opens the key editor.
                            Button(action: { editedEntry = entry }) {
                                HStack(spacing: DS.Padding.m) {
                                    KeyboardBarKeyGlyph(key: entry.key, size: 28, maxCharacters: 8)
                                    entryLabel(entry.key)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(DS.Font.detail)
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.primary)
                            .accessibilityHint(Text("Edit Key"))
                        } else {
                            KeyboardBarKeyGlyph(key: entry.key, size: 28, maxCharacters: 8)
                            Text(entry.key.displayName)
                        }
                    }
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("On the Bar")
                    .font(DS.Font.caption)
            } footer: {
                Text("Drag to reorder, tap a character key to edit it. Removing a standard key returns it to More Keys; dividers and custom keys are deleted.")
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
                        KeyboardBarKeyGlyph(key: key, size: 28, maxCharacters: 8)
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
                    "A custom key types the characters you enter, together with any modifier keys that are switched on.",
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
                Text(
                    """
                    The bar stays down while you type on a hardware keyboard. It \
                    comes back with the onscreen keyboard, such as when a \
                    keyboard case is folded back.
                    """,
                )
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

        /// A custom key drawn as something other than its text names what it
        /// sends underneath.
        @ViewBuilder
        private func entryLabel(_ key: KeyboardBarKey) -> some View {
            if key.look != nil, let text = key.sentText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.displayName)
                        .multilineTextAlignment(.leading)
                    Text(String(
                        format: NSLocalizedString("Sends “%@”", comment: "What a custom accessory key types"),
                        text,
                    ))
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            } else {
                Text(key.displayName)
                    .multilineTextAlignment(.leading)
            }
        }

        private func remove(_ entry: KeyboardBarStore.Entry) {
            withAnimation { store.remove(entry) }
        }
    }

    /// One key rendered the way the accessory bar itself renders it: the same
    /// circular backdrop — a capsule around a label wider than the circle —
    /// the same SF Symbol or monospaced label, and the same small dot for a
    /// divider.
    struct KeyboardBarKeyGlyph: View {
        let key: KeyboardBarKey
        var size: CGFloat = 36
        /// A list row's glyph shows at most this many characters of a label,
        /// so a long key leaves room for its name; the preview shows it whole.
        var maxCharacters: Int?

        var body: some View {
            Group {
                if key == .divider {
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 6, height: 6)
                        .frame(width: size, height: size)
                } else if let systemImage = key.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: size, height: size)
                        .background(
                            Circle().fill(Color(uiColor: .systemGray5).opacity(0.92)),
                        )
                } else if let label = key.accessoryItem.buttonTitle {
                    // The bar's own label: all of it, on one line.
                    Text(shortened(label))
                        .font(.system(size: size * 0.36, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, size * 0.22)
                        .frame(minWidth: size, minHeight: size, maxHeight: size)
                        .background(
                            Capsule().fill(Color(uiColor: .systemGray5).opacity(0.92)),
                        )
                }
            }
            .accessibilityHidden(true)
        }

        private func shortened(_ label: String) -> String {
            guard let maxCharacters, label.count > maxCharacters else { return label }
            return label.prefix(maxCharacters - 1) + "…"
        }
    }

    /// Entry sheet for a free-form key, new or edited: what it types, and how
    /// the bar draws it. A sheet rather than an alert because alert text
    /// fields only exist from iOS 16 and this app supports 15.
    private struct CustomKeySheet: View {
        private enum LookKind: Hashable {
            case text
            case symbol
        }

        let isEditing: Bool
        let onSave: (KeyboardBarKey) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var text: String
        @State private var lookKind: LookKind
        @State private var label: String
        @State private var symbolName: String

        private static let placeholder = "|"
        private static let symbolPlaceholder = "hammer.fill"

        init(editing key: KeyboardBarKey?, onSave: @escaping (KeyboardBarKey) -> Void) {
            isEditing = key != nil
            self.onSave = onSave
            _text = State(initialValue: key?.sentText ?? "")
            switch key?.look {
            case let .label(label):
                _lookKind = State(initialValue: .text)
                _label = State(initialValue: label)
                _symbolName = State(initialValue: "")
            case let .systemImage(name):
                _lookKind = State(initialValue: .symbol)
                _label = State(initialValue: "")
                _symbolName = State(initialValue: name)
            case nil:
                _lookKind = State(initialValue: .text)
                _label = State(initialValue: "")
                _symbolName = State(initialValue: "")
            }
        }

        private var trimmed: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var trimmedLabel: String {
            label.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var trimmedSymbolName: String {
            symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var symbolExists: Bool {
            UIImage(systemName: trimmedSymbolName) != nil
        }

        /// The key as it stands; a key with no label of its own is a plain
        /// symbol key.
        private var key: KeyboardBarKey {
            switch lookKind {
            case .text:
                trimmedLabel.isEmpty ? .symbol(trimmed) : .custom(text: trimmed, look: .label(trimmedLabel))
            case .symbol:
                .custom(text: trimmed, look: .systemImage(trimmedSymbolName))
            }
        }

        private var isValid: Bool {
            !trimmed.isEmpty && (lookKind == .text || symbolExists)
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
                    } header: {
                        Text("Sends")
                    } footer: {
                        Text("Sent exactly as typed. A single letter also works with Control.")
                            .font(DS.Font.detail)
                    }

                    Section {
                        Picker("Appearance", selection: $lookKind) {
                            Text("Text").tag(LookKind.text)
                            Text("Symbol").tag(LookKind.symbol)
                        }
                        .pickerStyle(.segmented)

                        switch lookKind {
                        case .text:
                            TextField(trimmed.isEmpty ? Self.placeholder : trimmed, text: $label)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .accessibilityLabel("Label")
                        case .symbol:
                            TextField(Self.symbolPlaceholder, text: $symbolName)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .accessibilityLabel("SF Symbol Name")
                        }

                        if isValid {
                            HStack {
                                Spacer()
                                KeyboardBarKeyGlyph(key: key)
                                Spacer()
                            }
                        }
                    } header: {
                        Text("Appearance")
                    } footer: {
                        Group {
                            switch lookKind {
                            case .text:
                                Text("The key shows this label instead of what it sends. Leave it empty to show the characters themselves.")
                            case .symbol:
                                if !trimmedSymbolName.isEmpty, !symbolExists {
                                    Text("No SF Symbol has this name.")
                                } else {
                                    Text("The key shows this SF Symbol, such as folder or hammer.fill.")
                                }
                            }
                        }
                        .font(DS.Font.detail)
                    }
                }
                .navigationTitle(isEditing ? "Edit Key" : "Custom Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isEditing ? "Save" : "Add") {
                            onSave(key)
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
