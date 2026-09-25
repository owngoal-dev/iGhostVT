//
//  SessionsSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What happens to running sessions when the app quits. Under Advanced,
/// below the default shell: it changes what quitting means, which is not
/// an everyday choice.
struct SessionsSettingsSection: View {
    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true

    var body: some View {
        Section {
            Toggle("Keep Sessions Running", isOn: $keepAlive)
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                Sessions with a program running keep going after the app quits \
                and come back on the next launch; a shell sitting at its prompt \
                closes. Turn this off to close every session when the app quits.
                """,
            )
            .font(DS.Font.detail)
        }
    }
}
