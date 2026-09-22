//
//  AdvancedSettingsView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// The settings a regular user never needs, off the main sheet so they
/// don't read as things to fill in: the shell every terminal runs, what
/// happens to sessions at quit, the Mac's background helper, and the
/// keystroke-level log.
struct AdvancedSettingsView: View {
    @ObservedObject private var agent = MacLaunchAgent.shared

    /// Read by the daemon when spawning shells. Empty means "let the daemon
    /// pick", using the session user's configured shell or its fallback.
    @AppStorage("Shell.path") private var shellPath = ""
    @State private var availableShellPaths: [String]?
    @State private var isEditingCustomShell = false
    @FocusState private var shellPathIsFocused: Bool

    /// Mirrored by AppDelegate at launch; toggling applies immediately.
    @AppStorage("Debug.verboseTerminalLog") private var verboseTerminalLog = false

    /// The rendered configuration follows the theme and the terminal size,
    /// so the view watches both and re-renders on a change to either.
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            shellSection
            SessionsSettingsSection()
            terminalHelperSection
            debugSection
            configurationSection
            SettingsFormSpacer()
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAvailableShellPaths)
    }

    private var shellSection: some View {
        Section {
            HStack {
                Label("Shell", systemImage: "terminal")
                    .layoutPriority(1)
                Spacer()
                // Buttons, not a Picker: Catalyst draws a Picker inside a
                // Menu as a submenu titled with the picker's label, so the
                // two sections came out as two identically named submenus.
                Menu {
                    shellChoice(String(localized: "Automatic"), path: "")
                    Divider()
                    ForEach(availableShellPaths ?? [], id: \.self) { path in
                        shellChoice(path, path: path)
                    }
                    Divider()
                    Button("Custom…") {
                        isEditingCustomShell = true
                        DispatchQueue.main.async {
                            shellPathIsFocused = true
                        }
                    }
                } label: {
                    HStack(spacing: DS.Padding.xs) {
                        Text(shellPath.isEmpty ? String(localized: "Automatic") : shellPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .accessibilityLabel("Default Shell")
                .accessibilityValue(shellPath.isEmpty ? String(localized: "Automatic") : shellPath)
            }

            if showsCustomShellPath {
                TextField("Custom Path", text: $shellPath)
                    .focused($shellPathIsFocused)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
        } header: {
            Text("Default Shell")
                .font(DS.Font.caption)
        } footer: {
            // The bootstrap-root caveat is a device matter; a Mac has no
            // bootstrap to prefix a path with.
            #if targetEnvironment(macCatalyst)
                Text(
                    """
                    Choose Automatic to use your login shell. Enter a custom \
                    executable path when it is not listed above.
                    """
                )
                .font(DS.Font.detail)
            #else
                Text(
                    """
                    Choose Automatic to use the default login shell. Custom paths \
                    must not include the bootstrap root, which can change when the \
                    environment is recreated.
                    """
                )
                .font(DS.Font.detail)
            #endif
        }
    }

    /// One row of the shell menu, checked when it is the current choice.
    @ViewBuilder
    private func shellChoice(_ title: String, path: String) -> some View {
        Button {
            shellPath = path
            isEditingCustomShell = false
            shellPathIsFocused = false
        } label: {
            if shellPath == path {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
    }

    private var showsCustomShellPath: Bool {
        if isEditingCustomShell { return true }
        guard let availableShellPaths, !shellPath.isEmpty else { return false }
        return !availableShellPaths.contains(shellPath)
    }

    private func loadAvailableShellPaths() {
        XPCDaemonTransport.listShells { paths in
            guard let paths else { return }
            Task { @MainActor in
                availableShellPaths = paths
            }
        }
    }

    /// Read-only: the helper registers itself on every launch, and the one
    /// control that removes it is the system's — Login Items in System
    /// Settings — so the footer points there instead of duplicating it.
    @ViewBuilder
    private var terminalHelperSection: some View {
        #if targetEnvironment(macCatalyst)
            if agent.status != .unsupported {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(agentStatusDescription)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Status")
                    .accessibilityValue(agentStatusDescription)
                } header: {
                    Text("Terminal Helper")
                        .font(DS.Font.caption)
                } footer: {
                    Text(
                        """
                        iGhostVT opens terminals through a helper that runs in \
                        the background, so sessions keep going while the app is \
                        closed. It is set up automatically. To remove it, turn \
                        iGhostVT off under Login Items in System Settings.
                        """
                    )
                    .font(DS.Font.detail)
                }
            }
        #endif
    }

    private var agentStatusDescription: String {
        switch agent.status {
        case .enabled:
            String(localized: "On")
        case .needsApproval:
            String(localized: "Waiting for Approval")
        case .rebinding:
            String(localized: "Updating")
        case .needsRelocation:
            String(localized: "Not in Applications")
        case .notRegistered:
            String(localized: "Off")
        case .brokenInstallation:
            String(localized: "Broken Installation")
        case let .failed(reason):
            reason
        case .notApplicable, .unsupported:
            String(localized: "Not Available")
        }
    }

    /// The keystroke log's switch and the way into the logs themselves —
    /// what the switch writes lands there, beside everything else the app
    /// and its helper record.
    private var debugSection: some View {
        Section {
            Toggle("Detailed Terminal Log", isOn: $verboseTerminalLog)
                .onChange(of: verboseTerminalLog) { enabled in
                    TerminalDebugLog.enable(enabled ? .standard : [.lifecycle, .metrics])
                }
            NavigationLink {
                LogViewerView()
            } label: {
                Text("Logs")
            }
        } header: {
            Text("Debugging")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                Writes detailed terminal activity to the log, \
                including every keystroke, while this is on.
                """
            )
            .font(DS.Font.detail)
        }
    }

    /// The last word: the configuration file every new terminal is opened
    /// with, as ghostty reads it — the library's base, the app's overlay
    /// (the font size preference lives there), then the theme in the
    /// current appearance. Read-only; it is here so what the settings above
    /// add up to can be checked in one place.
    private var configurationSection: some View {
        Section {
            ConfigurationFileView(
                contents: GhosttyAppConfiguration.renderedConfig(
                    for: colorScheme == .dark ? .dark : .light
                )
            )
            .listRowInsets(EdgeInsets())
            // `terminalFontSize` and `theme` are what the file is made of; a
            // read here is what makes SwiftUI re-render on their change.
            .id("\(terminalFontSize)-\(theme.selection.lightName ?? "")-\(theme.selection.darkName ?? "")")
        } header: {
            Text("Configuration")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                The Ghostty configuration every new terminal opens with, \
                generated from the settings above. Open tabs keep the \
                configuration they were opened with.
                """
            )
            .font(DS.Font.detail)
        }
    }
}

/// A configuration file drawn as a code block: a title strip naming the
/// file with a line count and a Copy control, the contents beneath in
/// monospace, scrolling sideways so long values never wrap and the file
/// reads as it would in an editor.
private struct ConfigurationFileView: View {
    let contents: String

    @State private var copied = false

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
                    lines.count
                ))
                .font(DS.Font.caption)
                .foregroundColor(Color.secondary.opacity(0.7))
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(DS.Font.captionEmphasis)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundColor(copied ? .green : .accentColor)
                .animation(DS.Motion.smooth, value: copied)
            }
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.s)
            .background(Color(.tertiarySystemFill))

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
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func copy() {
        UIPasteboard.general.string = contents
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
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
