//
//  SessionsSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What happens to sessions as the app opens and quits, right under the
/// shell those sessions run.
struct SessionsSettingsSection: View {
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true

    var body: some View {
        Section {
            Toggle("New Session at Launch", isOn: $opensNewSession)
            // Ghost Remote's sessions live on other devices, which keep
            // them whatever this app does.
            if !AppEdition.isRemoteOnly {
                Toggle("Keep Sessions Running", isOn: $keepAlive)
            }
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text(
                    """
                    New Session at Launch opens a session when the app starts \
                    with nothing to resume. With it off, the app opens with no tabs.
                    """,
                )
                if !AppEdition.isRemoteOnly {
                    keepAliveFooter
                }
            }
            .font(DS.Font.detail)
        }
    }

    private var keepAliveFooter: some View {
        Text(
            """
            Keep Sessions Running keeps every session going after the app \
            quits, and the next launch brings them all back as tabs. With \
            it off, every session closes when the app quits.
            """,
        )
    }
}
