import SwiftUI

/// Settings ▸ Remote Access: this device as a host (the switch, the devices
/// that may connect, pairing a new one), its relay, and this device as a
/// client (one list: the devices it is paired with, then the ones nearby or
/// at the relay to pair with).
/// Pushed from the settings sheet on iPhone and iPad; the Mac has a pane
/// of its own (`MacRemotePane`).
struct RemoteAccessView: View {
    @StateObject private var model = RemoteAccessModel()
    @ObservedObject private var directory = RemoteHostDirectory.shared

    @State private var isShowingPairingCode = false
    @State private var pairingHost: DiscoveredRemoteHost?
    @State private var name = RemoteDeviceIdentity.chosenName ?? ""
    @State private var isConfirmingRelayRemoval = false

    var body: some View {
        Form {
            nameSection
            // Ghost Remote is never a host: it has no daemon to open
            // terminals in.
            if !AppEdition.isRemoteOnly {
                thisDeviceSection
                if model.isEnabled {
                    allowedDevicesSection
                }
            }
            // Only once a .vtrpsc file has been opened: no relay, no section.
            if let relay = directory.relay {
                relaySection(relay)
            }
            yourDevicesSection
        }
        .animation(DS.Motion.smooth, value: model.isEnabled)
        .navigationTitle("Remote Access")
        // Said outright rather than inherited: pushed as the sheet appears
        // (a relay file that launched the app), it came up with a large title.
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.appear()
            directory.start()
            RelayImport.remoteAccessOnScreen += 1
        }
        .onDisappear {
            saveName()
            model.disappear()
            RelayImport.remoteAccessOnScreen -= 1
        }
        .sheet(isPresented: $isShowingPairingCode) {
            RemotePairingCodeView(model: model)
        }
        .sheet(item: $pairingHost) { host in
            RemotePairDeviceView(host: host)
        }
    }

    // MARK: - This device

    /// What the other devices call this one, in their lists and on their
    /// tabs. Empty is the name set on the device.
    private var nameSection: some View {
        Section {
            TextField(RemoteDeviceIdentity.systemName, text: $name)
                .disableAutocorrection(true)
                .onSubmit(saveName)
        } header: {
            Text("Name")
                .font(DS.Font.caption)
        } footer: {
            Text("Your other devices see this device by this name. Leave it empty to use the name set on the device.")
                .font(DS.Font.detail)
        }
    }

    private func saveName() {
        guard name != (RemoteDeviceIdentity.chosenName ?? "") else { return }
        model.setName(name)
    }

    private var thisDeviceSection: some View {
        Section {
            Toggle("Allow Remote Access", isOn: Binding(
                get: { model.isEnabled },
                set: { model.setEnabled($0) },
            ))
            .disabled(!model.hasLoaded || model.status.isUnavailable)
            // Said only when something is wrong; the switch says the rest.
            if let problem {
                SettingsValueText(title: "Status", value: problem, isWarning: true)
            }
        }
    }

    // MARK: - Relay

    private func relaySection(_ relay: RelayConfiguration) -> some View {
        Section {
            SettingsValueText(title: "Relay", value: relay.name)
            SettingsValueText(title: "Address", value: relay.endpointDescription)
            if let status = RelayStatusText.describe(model.status, directory: directory) {
                SettingsValueText(title: "Status", value: status.text, isWarning: status.isProblem)
            }
            Button("Remove Relay", role: .destructive) {
                isConfirmingRelayRemoval = true
            }
            .confirmationDialog(
                "Remove the relay?",
                isPresented: $isConfirmingRelayRemoval,
                titleVisibility: .visible,
            ) {
                Button("Remove Relay", role: .destructive) {
                    RelayConfigurationStore.remove()
                }
            } message: {
                Text("Devices that are not on the same network can no longer reach each other.")
            }
        } header: {
            Text("Relay")
                .font(DS.Font.caption)
        }
    }

    private var problem: String? {
        Self.problem(model)
    }

    /// What is wrong with the host side, or nil when nothing is.
    static func problem(_ model: RemoteAccessModel) -> String? {
        if model.status.isUnavailable {
            return String(localized: "Terminal helper is not running")
        }
        guard model.isEnabled, model.status.state == .failed else { return nil }
        return model.status.failureMessage ?? String(localized: "Unable to start")
    }

    private var allowedDevicesSection: some View {
        Section {
            ForEach(model.status.devices) { device in
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    Text(Self.lastSeenText(device))
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        model.revoke(device)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    model.revoke(model.status.devices[index])
                }
            }
            Button("Pair New Device…") {
                Task {
                    await model.beginPairing()
                    isShowingPairingCode = true
                }
            }
            .disabled(model.status.state != .listening)
        } header: {
            Text("Authorized Devices")
                .font(DS.Font.caption)
        } footer: {
            if !model.status.devices.isEmpty {
                Text("A removed device loses access at once and has to pair again.")
                    .font(DS.Font.detail)
            }
        }
    }

    static func lastSeenText(_ device: RemoteAccessStatus.Device) -> String {
        guard let lastSeen = device.lastSeen else {
            return String(localized: "Not connected yet")
        }
        let relative = RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date())
        return String.localizedStringWithFormat(
            NSLocalizedString("Connected %@", comment: "%@ is a relative time, such as “5 minutes ago”"),
            relative,
        )
    }

    // MARK: - Other devices

    /// The devices this one is paired with, then — in a section of their
    /// own, as Bluetooth settings list them — the ones it could pair with.
    @ViewBuilder
    private var yourDevicesSection: some View {
        Section {
            ForEach(directory.paired) { host in
                NavigationLink {
                    RemoteHostDetailView(hostID: host.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            DeviceNameText(name: host.displayName, address: directory.address(of: host))
                            if let theirs = directory.mismatchedVersion(of: host.id) {
                                Text(RemoteVersionText.needsUpdate(theirs: theirs))
                                    .font(DS.Font.detail)
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                        Text(Self.whereabouts(of: host.id, in: directory))
                            .foregroundColor(.secondary)
                    }
                }
            }
            if directory.paired.isEmpty, unpairedNearby.isEmpty, directory.unpairedAtRelay.isEmpty {
                Group {
                    if directory.relay == nil {
                        Text("Devices on this network with remote access on appear here.")
                    } else {
                        Text("Devices on this network or at the relay with remote access on appear here.")
                    }
                }
                .foregroundColor(.secondary)
            }
        } header: {
            Text("Accessible Devices")
                .font(DS.Font.caption)
        }
        if !(unpairedNearby + directory.unpairedAtRelay).isEmpty {
            Section {
                ForEach(unpairedNearby + directory.unpairedAtRelay) { host in
                    Button {
                        pairingHost = host
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                DeviceNameText(name: host.name, address: host.address)
                                    .foregroundColor(.primary)
                                if host.viaRelay {
                                    Text("Through relay")
                                        .font(DS.Font.detail)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text("Pair")
                        }
                    }
                }
            } header: {
                Text("Other Devices")
                    .font(DS.Font.caption)
            }
        }
    }

    private var unpairedNearby: [DiscoveredRemoteHost] {
        directory.unpairedNearby
    }

    /// Where a paired device can be reached right now: here, through the
    /// relay, or nowhere that is known.
    static func whereabouts(of hostID: String, in directory: RemoteHostDirectory) -> String {
        if directory.isDiscovered(hostID) {
            return String(localized: "Nearby")
        }
        if directory.isAtRelay(hostID) {
            return String(localized: "Relay")
        }
        return ""
    }
}

/// A device as a list names it: `iPad @192.168.1.20`, the address in the
/// secondary colour — two devices may well share a name.
struct DeviceNameText: View {
    let name: String
    let address: String?

    var body: some View {
        if let address {
            Text(name) + Text(verbatim: " @\(address)").foregroundColor(.secondary)
        } else {
            Text(name)
        }
    }
}

/// A label and its value on one row, the value trailing in the secondary
/// colour.
struct SettingsValueText: View {
    let title: LocalizedStringKey
    let value: String
    var isWarning = false

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(isWarning ? .red : .secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
