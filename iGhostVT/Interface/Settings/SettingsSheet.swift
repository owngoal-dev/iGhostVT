//
//  SettingsSheet.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

/// The settings page on iPhone and iPad: one section per file under
/// `Sections/`, stacked in a Form. The sheet itself only owns navigation
/// and the Close control. The Mac has a settings window instead
/// (`SettingsWindow`).
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Remote Access, pushed by itself for a relay file opened while the
    /// sheet is up or one that opened it (`RelayImport`): that page is
    /// where the file is asked about.
    @State private var isShowingRemoteAccess = false
    /// Set before the sheet is asked for (`WindowInterfaceState
    /// .showRemoteAccess`): the sheet opens on Remote Access. A value
    /// subject, so a sheet that appears after the request still reads it.
    static let remoteAccessRequest = CurrentValueSubject<Bool, Never>(false)

    var body: some View {
        NavigationView {
            Form {
                AppearanceSettingsSection()
                TextSizeSettingsSection()
                if !AppEdition.isRemoteOnly {
                    ShellSettingsSection()
                }
                SessionsSettingsSection()
                RemoteAccessSettingsSection()
                RecentDirectoriesSettingsSection()
                KeyboardSettingsSection()
                AboutSettingsSection()
            }
            // Out here, not on the section's row: a Form builds its rows
            // as they scroll into view, and a link in a row not built yet
            // cannot be followed.
            .background(
                NavigationLink(isActive: $isShowingRemoteAccess) {
                    RemoteAccessView()
                } label: {
                    EmptyView()
                },
            )
            .onReceive(RelayImport.pending) { request in
                if request != nil, RelayImport.remoteAccessOnScreen == 0 {
                    isShowingRemoteAccess = true
                }
            }
            .onReceive(Self.remoteAccessRequest) { requested in
                guard requested else { return }
                Self.remoteAccessRequest.send(false)
                if RelayImport.remoteAccessOnScreen == 0 {
                    isShowingRemoteAccess = true
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SettingsCloseButton {
                        dismiss()
                    }
                    .fixedSize()
                }
            }
        }
        .navigationViewStyle(.stack)
        // On the sheet, not on Remote Access: one asker however deep the
        // navigation is, so a file opened from a page under Remote Access is
        // still asked about once.
        .relayImportPrompt()
    }
}

private struct SettingsCloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context _: Context) -> UIButton {
        UIButton(type: .close, primaryAction: UIAction { _ in action() })
    }

    func updateUIView(_: UIButton, context _: Context) {}
}
