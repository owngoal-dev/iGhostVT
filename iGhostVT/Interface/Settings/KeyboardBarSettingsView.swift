//
//  KeyboardBarSettingsView.swift
//  iGhostVT
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
                                    rowGlyph(entry.key)
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
                            rowGlyph(entry.key)
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
                        rowGlyph(key)
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

        /// A list row's picture of a key. A plain symbol key's circle stays
        /// empty — its name already spells what it types.
        @ViewBuilder
        private func rowGlyph(_ key: KeyboardBarKey) -> some View {
            if case .symbol = key {
                Circle()
                    .fill(Color(uiColor: .systemGray5).opacity(0.92))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                KeyboardBarKeyGlyph(key: key, size: 28, maxCharacters: 8)
            }
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
                } else if case let .custom(_, .picture(name)) = key,
                          let picture = KeyboardBarPictures.image(named: name)
                {
                    // The bar fills the circle with it, cropped to the edge.
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
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

    /// Entry sheet for a free-form key, new or edited: what it types, and an
    /// optional nickname the bar shows instead. A sheet rather than an alert
    /// because alert text fields only exist from iOS 16 and this app
    /// supports 15.
    ///
    /// Hidden for now: an image dropped on the sheet brings up a switch that
    /// fills the key with it, and a button that throws it away. Nothing on
    /// the sheet mentions it until then.
    private struct CustomKeySheet: View {
        let isEditing: Bool
        /// A key drawn as an SF Symbol keeps it while no nickname is given;
        /// the editor itself does not offer symbols.
        private let symbolLook: KeyboardBarKeyLook?
        let onSave: (KeyboardBarKey) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var text: String
        @State private var nickname: String
        /// The key's saved picture, until a drop replaces it or it is deleted.
        @State private var pictureName: String?
        @State private var droppedPicture: UIImage?
        @State private var fillsWithPicture: Bool

        private static let placeholder = "|"

        init(editing key: KeyboardBarKey?, onSave: @escaping (KeyboardBarKey) -> Void) {
            isEditing = key != nil
            self.onSave = onSave
            _text = State(initialValue: key?.sentText ?? "")
            _droppedPicture = State(initialValue: nil)
            switch key?.look {
            case let .label(label):
                _nickname = State(initialValue: label)
                _pictureName = State(initialValue: nil)
                _fillsWithPicture = State(initialValue: false)
                symbolLook = nil
            case let .picture(name):
                _nickname = State(initialValue: "")
                _pictureName = State(initialValue: name)
                _fillsWithPicture = State(initialValue: true)
                symbolLook = nil
            case let look?:
                _nickname = State(initialValue: "")
                _pictureName = State(initialValue: nil)
                _fillsWithPicture = State(initialValue: false)
                symbolLook = look
            case nil:
                _nickname = State(initialValue: "")
                _pictureName = State(initialValue: nil)
                _fillsWithPicture = State(initialValue: false)
                symbolLook = nil
            }
        }

        private var trimmed: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var trimmedNickname: String {
            nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var hasPicture: Bool {
            droppedPicture != nil || pictureName != nil
        }

        /// The key as it stands; one with no nickname of its own is a plain
        /// symbol key. A dropped picture is written only here, on Save.
        private func makeKey() -> KeyboardBarKey {
            if fillsWithPicture, let name = droppedPicture.flatMap(KeyboardBarPictures.save) ?? pictureName {
                return .custom(text: trimmed, look: .picture(name))
            }
            if !trimmedNickname.isEmpty {
                return .custom(text: trimmed, look: .label(trimmedNickname))
            }
            if let symbolLook {
                return .custom(text: trimmed, look: symbolLook)
            }
            return .symbol(trimmed)
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
                        TextField(trimmed.isEmpty ? Self.placeholder : trimmed, text: $nickname)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .accessibilityLabel("Nickname")
                        if hasPicture {
                            Toggle("Fill with Image", isOn: $fillsWithPicture)
                            Button("Delete Image", role: .destructive) {
                                droppedPicture = nil
                                pictureName = nil
                                fillsWithPicture = false
                            }
                        }
                    } header: {
                        Text("Nickname")
                    } footer: {
                        Text("The key shows this nickname instead of what it sends. Leave it empty to show the characters themselves.")
                            .font(DS.Font.detail)
                    }
                }
                .onDrop(of: [.image], isTargeted: nil, perform: acceptDrop)
                .navigationTitle(isEditing ? "Edit Key" : "Custom Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isEditing ? "Save" : "Add") {
                            onSave(makeKey())
                            dismiss()
                        }
                        .disabled(trimmed.isEmpty)
                    }
                }
            }
            .navigationViewStyle(.stack)
        }

        private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
                return false
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    droppedPicture = image
                    fillsWithPicture = true
                }
            }
            return true
        }
    }

#endif
