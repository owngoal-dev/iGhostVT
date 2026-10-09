//
//  MacSettingsTables.swift
//  iGhostVT
//

import SwiftUI

#if targetEnvironment(macCatalyst)

    /// A Mac table's frame: the content on the text background, a hairline
    /// border, rows that alternate their fill. The panes that list many
    /// things (shortcuts, licenses) draw their rows in one of these rather
    /// than as an iOS grouped list.
    struct MacTableFrame<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            content()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 1),
                )
        }
    }

    /// The fill of the row at `index`: every other row is tinted.
    enum MacTableStripe {
        static func color(_ index: Int) -> Color {
            index.isMultiple(of: 2) ? .clear : Color(.secondarySystemBackground).opacity(0.6)
        }
    }

    private func stripe(_ index: Int) -> Color {
        MacTableStripe.color(index)
    }

    /// Every shortcut as a table row: a checkmark column (on or off), what
    /// the shortcut does, and its keys — grouped the way the menu groups
    /// them. Unchecked, the key reaches the program in the terminal.
    struct MacShortcutsPane: View {
        /// Flipped on every change so the rows re-read UserDefaults.
        @State private var revision = 0

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.m) {
                MacTableFrame {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(ShortcutGroup.allCases, id: \.self) { group in
                                Text(group.title)
                                    .font(DS.Font.captionEmphasis)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, DS.Padding.m)
                                    .padding(.top, DS.Padding.m)
                                    .padding(.bottom, DS.Padding.xs)
                                let shortcuts = KeyShortcuts.listed(in: group)
                                ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                    row(shortcut)
                                        .background(stripe(index))
                                }
                            }
                        }
                        .padding(.bottom, DS.Padding.s)
                    }
                }
                MacSettingsNote(
                    "A shortcut that is off hands its key to the program running in the terminal. Escape always reaches the terminal.",
                )
            }
            .padding(DS.Padding.xl)
        }

        private func row(_ shortcut: KeyShortcut) -> some View {
            let isOn = { _ = revision; return shortcut.isEnabled }()
            return Button {
                KeyShortcuts.setEnabled(!isOn, for: shortcut)
                revision += 1
            } label: {
                HStack(spacing: DS.Padding.m) {
                    MacCheckboxBox(isOn: isOn)
                    Text(shortcut.title)
                        .foregroundColor(.primary)
                    Spacer(minLength: DS.Padding.m)
                    Text(verbatim: shortcut.display)
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, DS.Padding.m)
                .padding(.vertical, DS.Padding.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
        }
    }

    /// Every license the app ships under: the components in a table on the
    /// leading side, the selected one's text beside it.
    struct MacLicensesBrowser: View {
        @State private var selectedID: String? = LicenseCatalog.entries.first?.id

        var body: some View {
            let entries = LicenseCatalog.entries
            if entries.isEmpty {
                Text("No license information is available.")
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: DS.Padding.m) {
                    MacTableFrame {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, index: index)
                                }
                            }
                        }
                    }
                    .frame(width: 210)
                    MacTableFrame {
                        if let entry = entries.first(where: { $0.id == selectedID }) {
                            LicenseTextView(entry: entry)
                                .id(entry.id)
                        }
                    }
                }
            }
        }

        private func row(_ entry: LicenseEntry, index: Int) -> some View {
            let isSelected = entry.id == selectedID
            return Button {
                selectedID = entry.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                        .lineLimit(1)
                    Text(verbatim: entry.shortSummary)
                        .font(DS.Font.caption)
                        .opacity(0.7)
                        .lineLimit(1)
                }
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Padding.m)
                .padding(.vertical, DS.Padding.xs + 2)
                .background(isSelected ? Color.accentColor : stripe(index))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: entry.name))
            .accessibilityValue(entry.shortSummary)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    /// The user's own ghostty lines in an editor, and the whole file every
    /// new terminal opens with under it — the iPad page's two sections, laid
    /// out as a Mac pane.
    struct MacConfigurationPane: View {
        @AppStorage(GhosttyAppConfiguration.customConfigurationKey) private var customConfiguration = ""
        @ObservedObject private var theme = AppTheme.shared
        @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.m) {
                Text("Custom Configuration")
                    .font(DS.Font.labelEmphasis)
                MacTableFrame {
                    // `TextEditor` has no switch for smart quotes and dashes,
                    // so the binding straightens them as they arrive.
                    TextEditor(text: Binding(
                        get: { customConfiguration },
                        set: { customConfiguration = GhosttyAppConfiguration.straighteningPunctuation($0) },
                    ))
                    .font(.system(.footnote, design: .monospaced))
                    .disableAutocorrection(true)
                    .padding(DS.Padding.xs)
                    .overlay(alignment: .topLeading) {
                        if customConfiguration.isEmpty {
                            // Config syntax, not copy: the same on every locale.
                            Text(verbatim: "cursor-style = bar\nfont-thicken = false")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(Color(.placeholderText))
                                .padding(.top, 8 + DS.Padding.xs)
                                .padding(.leading, 5 + DS.Padding.xs)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Custom Configuration")
                }
                .frame(height: 110)
                MacSettingsNote("Only new tabs load the changed configuration.")
                MacTableFrame {
                    // The header stays; only the lines scroll.
                    ConfigurationFileView(
                        contents: GhosttyAppConfiguration.renderedConfig(
                            for: colorScheme == .dark ? .dark : .light,
                        ),
                        scrollsLines: true,
                    )
                    // `terminalFontSize` and `theme` are what the file is
                    // made of; a read here re-renders on their change.
                    .id("\(terminalFontSize)-\(theme.selection.lightName ?? "")-\(theme.selection.darkName ?? "")")
                }
            }
            .padding(DS.Padding.xl)
        }
    }

#endif
