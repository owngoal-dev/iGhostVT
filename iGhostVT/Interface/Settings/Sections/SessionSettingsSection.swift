//
//  SessionSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What the new-tab menu remembers, whether a quit leaves the sessions
/// running (Background Activities, `SessionKeepAlive`), and the way into
/// Settings ▸ Remote Access. The order differs by edition: Ghost Remote has
/// no sessions of its own, so it has no Background Activities, and Remote
/// Access — its whole purpose — leads. New Session at Launch is set once,
/// so it waits in Advanced (`AdvancedSettingsView`).
struct SessionSettingsSection: View {
    @ObservedObject private var recents = RecentDirectoryStore.shared
    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true
    /// Remote access holds Background Activities on (`SessionKeepAlive`).
    @AppStorage(SessionKeepAlive.remoteAccessKey) private var heldByRemoteAccess = false

    var body: some View {
        Section {
            if AppEdition.isRemoteOnly {
                remoteAccessLink
                Toggle("Recent Directories", isOn: $recents.isEnabled)
            } else {
                Toggle("Recent Directories", isOn: $recents.isEnabled)
                Toggle("Background Activities", isOn: Binding(
                    get: { keepAlive || heldByRemoteAccess },
                    set: { keepAlive = $0 },
                ))
                .disabled(heldByRemoteAccess)
                remoteAccessLink
            }
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            if !AppEdition.isRemoteOnly {
                if heldByRemoteAccess {
                    Text("Background Activities keeps your sessions running after you quit the app. It stays on while Remote Access is on, so paired devices can reach them.")
                        .font(DS.Font.detail)
                } else {
                    Text("Background Activities keeps your sessions running after you quit the app. With it off, shells and the tasks they run end when the app quits.")
                        .font(DS.Font.detail)
                }
            }
        }
    }

    private var remoteAccessLink: some View {
        NavigationLink {
            RemoteAccessView()
        } label: {
            Text("Remote Access")
        }
    }
}
