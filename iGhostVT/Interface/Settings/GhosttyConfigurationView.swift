//
//  GhosttyConfigurationView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// Settings ▸ Ghostty Configuration: the user's own ghostty lines, and the
/// file every new terminal is opened with once the app's settings and
/// those lines are added up.
struct GhosttyConfigurationView: View {
    @AppStorage(GhosttyAppConfiguration.customConfigurationKey) private var customConfiguration = ""

    /// The rendered configuration follows the theme and the terminal size,
    /// so the view watches both and re-renders on a change to either.
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            customSection
            renderedSection
        }
        .navigationTitle("Ghostty Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The user's own ghostty lines, appended after everything the app
    /// generates (`GhosttyAppConfiguration.theme`), so they win. Saved as
    /// typed; a new tab reads them when it is made.
    private var customSection: some View {
        Section {
            // `TextEditor` has no switch for smart quotes and dashes, so
            // the binding straightens them as they arrive.
            TextEditor(text: Binding(
                get: { customConfiguration },
                set: { customConfiguration = GhosttyAppConfiguration.straighteningPunctuation($0) },
            ))
            .font(.system(.footnote, design: .monospaced))
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .frame(minHeight: 120)
            .overlay(alignment: .topLeading) {
                if customConfiguration.isEmpty {
                    // Config syntax, not copy: the same on every locale.
                    Text(verbatim: "cursor-style = bar\nfont-thicken = false")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Color(.placeholderText))
                        // UITextView's own text inset, so the example
                        // sits where the first typed character will.
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Custom Configuration")
        } header: {
            Text("Custom Configuration")
                .font(DS.Font.caption)
        } footer: {
            Text("Only new tabs load the changed configuration.")
                .font(DS.Font.detail)
        }
    }

    /// The last word: the configuration file every new terminal is opened
    /// with, as ghostty reads it — the library's base, the app's overlay
    /// (the font size preference lives there), then the theme in the
    /// current appearance and the custom lines. Read-only, because it is
    /// generated; it is here so what the settings above add up to can be
    /// checked in one place. Editing happens in the custom lines above.
    private var renderedSection: some View {
        Section {
            ConfigurationFileView(
                contents: GhosttyAppConfiguration.renderedConfig(
                    for: colorScheme == .dark ? .dark : .light,
                ),
            )
            .listRowInsets(EdgeInsets())
            // `terminalFontSize` and `theme` are what the file is made of; a
            // read here is what makes SwiftUI re-render on their change.
            .id("\(terminalFontSize)-\(theme.selection.lightName ?? "")-\(theme.selection.darkName ?? "")")
        } header: {
            Text("Configuration")
                .font(DS.Font.caption)
        }
    }
}

/// A configuration file drawn as a code block: a title strip naming the
/// file with a line count and a Copy control, the contents beneath in
/// monospace, scrolling sideways so long values never wrap and the file
/// reads as it would in an editor.
struct ConfigurationFileView: View {
    let contents: String
    /// The lines scroll under a header that stays put (the Mac's pane,
    /// where the file has a fixed height); otherwise the whole view is as
    /// tall as the file and the page around it scrolls.
    var scrollsLines = false

    private var lines: [String] {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Padding.s) {
                Image(systemName: "doc.text")
                    .font(DS.Font.captionEmphasis)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                // A file name, not copy: the same on every locale.
                Text(verbatim: "ghostty.conf")
                    .font(DS.Font.captionEmphasis)
                    .foregroundColor(.secondary)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%lld lines", comment: "A line count"),
                    lines.count,
                ))
                .font(DS.Font.caption)
                .foregroundColor(Color.secondary.opacity(0.7))
                Spacer()
                // One label, never swapped: "Copied" with a checkmark is a
                // different height than "Copy", and the swap nudged the
                // whole section. The confirmation is the indicator.
                Button(action: copy) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(DS.Font.captionEmphasis)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.s)
            .background(Color(.tertiarySystemFill))

            if scrollsLines {
                ScrollView(.vertical) { numberedLines(lines) }
            } else {
                numberedLines(lines)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// The numbered lines, scrolling sideways for a long one.
    private func numberedLines(_ lines: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DS.Padding.m) {
                // Line numbers: right-aligned, dimmer than the text.
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(verbatim: "\(index + 1)")
                            .foregroundColor(Color.secondary.opacity(0.5))
                    }
                }
                // A gutter of bare numbers read one by one is noise; the
                // lines themselves carry the file.
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        ConfigurationLine(text: lines[index])
                    }
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(DS.Padding.m)
        }
        .textSelection(.enabled)
    }

    private func copy() {
        UIPasteboard.general.string = contents
        CopiedIndicator.present(in: nil)
    }
}

/// One `key = value` line, the key tinted so the file scans like code; a
/// line that is not of that shape (a comment, a blank) is drawn as it is.
private struct ConfigurationLine: View {
    let text: String

    var body: some View {
        if let separator = text.range(of: " = ") {
            (Text(verbatim: String(text[..<separator.lowerBound]))
                .foregroundColor(.accentColor)
                + Text(verbatim: " = ")
                .foregroundColor(.secondary)
                + Text(verbatim: String(text[separator.upperBound...]))
                .foregroundColor(.primary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(verbatim: text)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
