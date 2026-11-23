//
//  AdvancedSettingsView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI
import UIKit

/// What is set once or only troubleshooting needs, off the main sheet so
/// it doesn't read as something to fill in: the default shell, whether a
/// launch starts one, the experimental switches, the keystroke-level log
/// and the way into the logs, and the release package straight from
/// GitHub. The Mac has its own
/// pane for this (`MacSettingsPanes`), with the background helper's status
/// beside it.
struct AdvancedSettingsView: View {
    @AppStorage(DetailedTerminalLog.key) private var verboseTerminalLog = false
    @AppStorage(ZmodemSetting.key) private var zmodemEnabled = ZmodemSetting.defaultValue
    @AppStorage(SmoothScrolling.key) private var smoothScrolling = SmoothScrolling.defaultValue
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    @ObservedObject private var updates = UpdateCheck.shared
    @StateObject private var mcp = MCPServerModel()
    @State private var window: UIWindow?

    var body: some View {
        Form {
            // The shell is set once and rarely again, so it waits here
            // rather than on the main sheet. Ghost Remote runs none.
            if !AppEdition.isRemoteOnly {
                ShellSettingsSection()
                launchSection
            }
            fileTransferSection
            // The server needs this device's daemon, which Ghost Remote has none of.
            if !AppEdition.isRemoteOnly {
                MCPServerSection(model: mcp)
            }
            experimentalSection
            debugSection
            #if !targetEnvironment(macCatalyst)
                if UpdateCheck.isAvailable {
                    updatesSection
                }
            #endif
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .background(WindowReader(window: $window))
        .onAppear {
            mcp.setWindow(window)
            mcp.pageAppeared()
        }
        .onChange(of: window) { mcp.setWindow($0) }
        .onDisappear { mcp.pageDisappeared() }
    }

    private var launchSection: some View {
        Section {
            Toggle("New Session at Launch", isOn: $opensNewSession)
        } footer: {
            Text("New Session at Launch starts a shell on this device when there is nothing to resume.")
                .font(DS.Font.detail)
        }
    }

    private var fileTransferSection: some View {
        Section {
            Toggle("ZMODEM File Transfer", isOn: $zmodemEnabled)
        } header: {
            Text("File Transfer")
                .font(DS.Font.caption)
        }
    }

    /// What works but is not settled enough to be on by default.
    private var experimentalSection: some View {
        Section {
            Toggle("Smooth Scrolling", isOn: $smoothScrolling)
        } header: {
            Text("Experimental Features")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                Smooth Scrolling moves the text pixel by pixel as you scroll, \
                and lines it up on a row when you stop. Off, it moves a row at a time.
                """,
            )
            .font(DS.Font.detail)
        }
    }

    /// The keystroke log's switch and the way into the logs themselves —
    /// what the switch writes lands there, beside everything else the app
    /// and its helper record.
    private var debugSection: some View {
        Section {
            Toggle("Detailed Terminal Log", isOn: $verboseTerminalLog)
                .onChange(of: verboseTerminalLog, perform: DetailedTerminalLog.apply)
            NavigationLink {
                LogViewerView()
            } label: {
                Text("Logs")
            }
        } header: {
            Text("Debugging")
                .font(DS.Font.caption)
        }
    }

    #if !targetEnvironment(macCatalyst)
        /// The release's deb for this bootstrap, ahead of the APT
        /// repository. The check runs under an alert of its own.
        private var updatesSection: some View {
            Section {
                Button("Check for Updates") { updates.check(in: window) }
                    .disabled(updates.phase != .idle)
            } header: {
                Text("Updates")
                    .font(DS.Font.caption)
            }
        }
    #endif
}

enum ZmodemSetting {
    static let key = "Transfer.zmodemEnabled"
    static let defaultValue = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Settings ▸ Advanced ▸ Experimental Features. Off, a precision scroll —
/// a finger, a trackpad, a mouse — moves the terminal a row at a time, as
/// Ghostty does; on, by the pixel, brought to a row once it stops
/// (`TerminalScrollBehavior`). Every new surface reads it and `TerminalTab`
/// switches the open ones when it flips. Off by default while it is
/// experimental.
enum SmoothScrolling {
    static let key = "Terminal.smoothScrolling"
    static let defaultValue = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    static var behavior: TerminalScrollBehavior {
        isEnabled ? .settlesOnRow : .rowAtATime
    }
}

/// The keystroke-level log switch. Read by AppDelegate at launch; a flip
/// in Settings applies at once.
enum DetailedTerminalLog {
    static let key = "Debug.verboseTerminalLog"

    /// Verbose lines — libghostty's own, a chunk of output, a ZMODEM
    /// block — reach the journal only while this is on. Off, they went to
    /// the file all the same, and a download left eighty thousand lines.
    static func apply(_ enabled: Bool) {
        TerminalDebugLog.enable(enabled ? .standard : [])
        AppLog.writesVerbose = enabled
    }
}

extension MacLaunchAgent.Status {
    /// The helper's state as the Mac's settings window prints it.
    var settingsDescription: String {
        switch self {
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
}
