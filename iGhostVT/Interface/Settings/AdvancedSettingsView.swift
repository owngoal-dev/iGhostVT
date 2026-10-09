//
//  AdvancedSettingsView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI
import UIKit

/// What only troubleshooting needs, off the main sheet so it doesn't read
/// as something to fill in: the keystroke-level log and the way into the
/// logs, and the release package straight from GitHub. The Mac has its own
/// pane for this (`MacSettingsPanes`), with the background helper's status
/// beside it.
struct AdvancedSettingsView: View {
    @AppStorage(DetailedTerminalLog.key) private var verboseTerminalLog = false
    @AppStorage(ZmodemSetting.key) private var zmodemEnabled = ZmodemSetting.defaultValue
    @ObservedObject private var updates = UpdateCheck.shared
    @State private var window: UIWindow?

    var body: some View {
        Form {
            fileTransferSection
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
    }

    private var fileTransferSection: some View {
        Section {
            Toggle("ZMODEM File Transfer", isOn: $zmodemEnabled)
        } header: {
            Text("File Transfer")
                .font(DS.Font.caption)
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
