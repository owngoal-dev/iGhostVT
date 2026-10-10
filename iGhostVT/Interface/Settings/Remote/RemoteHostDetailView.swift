import SwiftUI

/// One paired device: name it, update a Mac, or forget it.
struct RemoteHostDetailView: View {
    let hostID: String
    @ObservedObject private var directory = RemoteHostDirectory.shared
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var window: UIWindow?

    private var host: PairedRemoteHost? {
        directory.paired.first { $0.id == hostID }
    }

    var body: some View {
        Form {
            if let host {
                Section {
                    TextField(host.name, text: $nickname)
                        .disableAutocorrection(true)
                        .onSubmit(saveNickname)
                } header: {
                    Text("Name")
                        .font(DS.Font.caption)
                } footer: {
                    Text("Leave this empty to use the name set on the device.")
                        .font(DS.Font.detail)
                }
                if host.lastSeen != nil || host.lastAddress != nil {
                    Section {
                        if let lastSeen = host.lastSeen {
                            SettingsValueText(
                                title: "Last Connected",
                                value: RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()),
                            )
                        }
                        if let address = host.lastAddress {
                            SettingsValueText(title: "Address", value: address)
                        }
                    }
                }
                Section {
                    Button("Check for Update") {
                        HostUpdateFlow.run(endpoint: .remote(hostID: hostID), in: window)
                    }
                } footer: {
                    Text("A Mac installs the latest iGhostVT on its own and restarts it, which ends its terminals. A jailbroken device updates through its package manager.")
                        .font(DS.Font.detail)
                }
                Section {
                    Button("Forget This Device", role: .destructive, action: confirmForget)
                } footer: {
                    Text("To connect again, pair it again.")
                        .font(DS.Font.detail)
                }
            }
        }
        .navigationTitle(host?.displayName ?? "")
        .onAppear {
            nickname = host?.nickname ?? ""
        }
        .onDisappear(perform: saveNickname)
        .background(WindowReader(window: $window))
    }

    private func saveNickname() {
        guard host != nil, nickname != (host?.nickname ?? "") else { return }
        PairedRemoteHostStore.setNickname(nickname, forHostID: hostID)
    }

    private func confirmForget() {
        guard let host else { return }
        AlertViewController(
            title: "Forget “\(host.displayName)”?",
            message: "To connect again, pair it again.",
            actions: [
                AlertAction("Cancel") {},
                AlertAction("Forget", kind: .highlighted) {
                    PairedRemoteHostStore.remove(id: hostID)
                    dismiss()
                },
            ],
        ).present(in: window)
    }
}
