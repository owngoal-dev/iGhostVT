//
//  MacRemotePane.swift
//  iGhostVT
//

import SwiftUI

#if targetEnvironment(macCatalyst)

    /// Settings ▸ Remote on the Mac: the same settings as the iPhone and
    /// iPad page (`RemoteAccessView`), read from the same model and
    /// directory, laid out as a Mac pane — a checkbox, the relay and a name
    /// field in the label column, then a count for each list of devices
    /// whose button opens that list in a sheet.
    struct MacRemotePane: View {
        @StateObject private var model = RemoteAccessModel()
        @ObservedObject private var directory = RemoteHostDirectory.shared

        @State private var name = RemoteDeviceIdentity.chosenName ?? ""
        @State private var selectedAllowedID: String?
        @State private var selectedHostID: String?
        @State private var isShowingPairingCode = false
        @State private var pairingHost: DiscoveredRemoteHost?
        @State private var window: UIWindow?
        @State private var isShowingAuthorized = false
        @State private var isShowingAccessible = false

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.l) {
                MacSettingsRow("Remote Access") {
                    MacCheckbox(String(localized: "Allow Remote Access"), isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) },
                    ))
                    .disabled(!model.hasLoaded || model.status.isUnavailable)
                } details: {
                    // A problem takes the note's line rather than adding one.
                    if let problem = RemoteAccessView.problem(model) {
                        Text(problem)
                            .font(DS.Font.detail)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
                // Only once a .vtrpsc file has been opened: no relay, no row.
                if let relay = directory.relay {
                    relayRow(relay)
                }
                MacSettingsRow("Name") {
                    TextField(RemoteDeviceIdentity.systemName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 300)
                        .onSubmit(saveName)
                } details: {
                    MacSettingsNote(
                        "Your other devices see this device by this name. Leave it empty to use the name set on the device.",
                    )
                }
                Divider()
                MacSettingsRow("Authorized") {
                    MacSheetLink(count: model.status.devices.count, label: "Authorized Devices") {
                        isShowingAuthorized = true
                    }
                } details: {
                    MacSettingsNote("Devices that may open terminals on this one.")
                }
                MacSettingsRow("Accessible") {
                    MacSheetLink(count: directory.paired.count, label: "Accessible Devices") {
                        isShowingAccessible = true
                    }
                } details: {
                    MacSettingsNote("Devices this one can open terminals on.")
                }
            }
            .padding(DS.Padding.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowReader(window: $window))
            .onAppear {
                model.appear()
                directory.start()
            }
            .onDisappear {
                saveName()
                model.disappear()
            }
            .sheet(isPresented: $isShowingAuthorized) {
                MacDeviceSheet(title: "Authorized Devices") {
                    // Off, the list is dimmed rather than hidden, so turning
                    // the switch moves nothing.
                    allowedDevices
                        .disabled(!model.isEnabled)
                        .opacity(model.isEnabled ? 1 : 0.5)
                }
            }
            .sheet(isPresented: $isShowingAccessible) {
                MacDeviceSheet(title: "Accessible Devices") {
                    yourDevices
                }
            }
            .relayImportPrompt()
        }

        // MARK: - Relay

        /// The relay's name with a small remove button after it, one line for
        /// the label to centre on; its address and how it is doing go under
        /// it.
        private func relayRow(_ relay: RelayConfiguration) -> some View {
            MacSettingsRow("Relay") {
                HStack(alignment: .firstTextBaseline, spacing: DS.Padding.s) {
                    Text(verbatim: relay.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MacInlineIconButton(symbol: "xmark.circle.fill", label: "Remove") {
                        RelayConfigurationStore.remove()
                    }
                }
            } details: {
                let status = RelayStatusText.describe(model.status, directory: directory)
                Text(verbatim: [relay.endpointDescription, status?.text].compactMap(\.self).joined(separator: " · "))
                    .font(DS.Font.detail)
                    .foregroundColor(status?.isProblem == true ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func saveName() {
            guard name != (RemoteDeviceIdentity.chosenName ?? "") else { return }
            model.setName(name)
        }

        // MARK: - This Mac as a host

        /// The devices that may open terminals here: + under the table pairs
        /// one more, the selected row's trash takes one away.
        private var allowedDevices: some View {
            MacTableFrame {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.status.devices.enumerated()), id: \.element.id) { index, device in
                                MacDeviceRow(
                                    name: device.name,
                                    address: nil,
                                    detail: RemoteAccessView.lastSeenText(device),
                                    index: index,
                                    isSelected: device.id == selectedAllowedID,
                                    select: { selectedAllowedID = device.id },
                                ) {
                                    MacRowIconButton(symbol: "trash", label: "Remove") {
                                        model.revoke(device)
                                        selectedAllowedID = nil
                                    }
                                }
                                .contextMenu {
                                    Button("Remove", role: .destructive) { model.revoke(device) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .overlay {
                        if model.status.devices.isEmpty {
                            Text("Pair a device to let it open terminals here.")
                                .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                        }
                    }
                    Divider()
                    MacTableBar {
                        Button {
                            Task {
                                await model.beginPairing()
                                isShowingPairingCode = true
                            }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 18)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Pair New Device…")
                        .disabled(model.status.state != .listening)
                        .popover(isPresented: $isShowingPairingCode, arrowEdge: .bottom) {
                            RemotePairingCodeView(model: model, isPopover: true)
                                .keepsPopover()
                        }
                    }
                }
            }
        }

        // MARK: - The other devices

        /// The devices this Mac is paired with, then the ones nearby it
        /// could pair with. The selected row carries its one action — trash
        /// to forget a paired device, Pair for one nearby.
        private var yourDevices: some View {
            let entries = accessibleEntries
            return MacTableFrame {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // One list, keyed by device: a device keeps its
                        // row as it pairs, and the row moves up into the
                        // paired ones with Pair turned into Forget.
                        ForEach(entries) { entry in
                            switch entry {
                            case .otherDevicesTitle:
                                MacTableSectionHeader(title: "Other Devices")
                            case let .device(device):
                                accessibleRow(device)
                            }
                        }
                    }
                }
                .overlay {
                    if entries.isEmpty {
                        Group {
                            if directory.relay == nil {
                                Text("Devices on this network with remote access on appear here.")
                            } else {
                                Text("Devices on this network or at the relay with remote access on appear here.")
                            }
                        }
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(DS.Padding.m)
                    }
                }
            }
        }

        /// The paired devices, then — under a title of their own, as
        /// Bluetooth settings list them — the ones not paired yet.
        private var accessibleEntries: [AccessibleEntry] {
            var entries = directory.paired.enumerated().map { index, host in
                AccessibleEntry.device(AccessibleDevice(
                    id: host.id,
                    name: host.displayName,
                    address: directory.address(of: host),
                    detail: directory.mismatchedVersion(of: host.id).map(RemoteVersionText.needsUpdate(theirs:))
                        ?? RemoteAccessView.whereabouts(of: host.id, in: directory),
                    index: index,
                    action: .forget(host),
                ))
            }
            let unpaired = directory.unpairedNearby + directory.unpairedAtRelay
            if !unpaired.isEmpty {
                entries.append(.otherDevicesTitle)
            }
            entries += unpaired.enumerated().map { index, host in
                AccessibleEntry.device(AccessibleDevice(
                    id: host.id,
                    name: host.name,
                    address: host.address,
                    detail: host.viaRelay ? String(localized: "Through relay") : "",
                    index: index,
                    action: .pair(host),
                ))
            }
            return entries
        }

        private func accessibleRow(_ device: AccessibleDevice) -> some View {
            MacDeviceRow(
                name: device.name,
                address: device.address,
                detail: device.detail,
                index: device.index,
                isSelected: device.id == selectedHostID,
                select: { selectedHostID = device.id },
            ) {
                switch device.action {
                case let .forget(host):
                    HStack(spacing: DS.Padding.xs) {
                        MacRowIconButton(symbol: "arrow.down.circle", label: "Check for Update") {
                            HostUpdateFlow.run(endpoint: .remote(hostID: host.id), in: window)
                        }
                        MacRowIconButton(symbol: "trash", label: "Forget") {
                            confirmForget(host)
                        }
                    }
                case let .pair(host):
                    Button {
                        pairingHost = host
                    } label: {
                        Text("Pair")
                            .font(DS.Font.labelEmphasis)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.borderless)
                }
            }
            // On the row rather than its Pair button, which pairing takes
            // away: the popover stays to say how it went, still pointing at
            // the row's trailing end, where Forget has taken Pair's place.
            .popover(
                item: Binding(
                    get: { pairingHost?.id == device.id ? pairingHost : nil },
                    set: { pairingHost = $0 },
                ),
                attachmentAnchor: .point(.trailing),
                arrowEdge: .trailing,
            ) { host in
                RemotePairDeviceView(host: host, isPopover: true)
                    .keepsPopover()
            }
        }

        private func confirmForget(_ host: PairedRemoteHost) {
            AlertViewController(
                title: "Forget “\(host.displayName)”?",
                message: "To connect again, pair it again.",
                actions: [
                    AlertAction("Cancel") {},
                    AlertAction("Forget", kind: .highlighted) {
                        PairedRemoteHostStore.remove(id: host.id)
                        selectedHostID = nil
                    },
                ],
            ).present(in: window)
        }
    }

    /// A row of the Accessible Devices table: a device, or the title over
    /// the ones not paired yet.
    private enum AccessibleEntry: Identifiable {
        case device(AccessibleDevice)
        case otherDevicesTitle

        var id: String {
            switch self {
            case let .device(device): device.id
            // No host id is empty.
            case .otherDevicesTitle: ""
            }
        }
    }

    private struct AccessibleDevice {
        enum Action {
            case forget(PairedRemoteHost)
            case pair(DiscoveredRemoteHost)
        }

        /// The host id, the same before and after it pairs.
        let id: String
        let name: String
        let address: String?
        let detail: String
        /// Its place in its own group, for the stripes.
        let index: Int
        let action: Action
    }

    /// One row of a device table: the name with its address dim after it,
    /// a dim trailing detail, striped, the selection in the accent with the
    /// row's action at its trailing end.
    private struct MacDeviceRow<Accessory: View>: View {
        let name: String
        let address: String?
        let detail: String
        let index: Int
        let isSelected: Bool
        let select: () -> Void
        @ViewBuilder let accessory: () -> Accessory

        var body: some View {
            HStack(spacing: DS.Padding.m) {
                Group {
                    if let address {
                        Text(verbatim: name)
                            + Text(verbatim: " @\(address)").foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                    } else {
                        Text(verbatim: name)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: DS.Padding.m)
                Text(verbatim: detail)
                    .font(DS.Font.detail)
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                if isSelected {
                    accessory()
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, DS.Padding.m)
            // The accessory never makes a row taller than one without.
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : MacTableStripe.color(index))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    /// A glyph button on a selected row, white on the accent.
    private struct MacRowIconButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }

    /// A small round glyph button set after a line of text, the text's own
    /// size and on its baseline (the caller's `HStack` aligns them).
    private struct MacInlineIconButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }

    /// "3 Devices" with the button that opens the list in a sheet.
    private struct MacSheetLink: View {
        let count: Int
        let label: LocalizedStringKey
        let open: () -> Void

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: DS.Padding.s) {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%lld Devices", comment: "Count of devices in a list"),
                    count,
                ))
                MacInlineIconButton(symbol: "arrow.up.right.circle.fill", label: label, action: open)
            }
        }
    }

    /// A list of devices on a sheet of its own: the title, the table filling
    /// the sheet, Done.
    private struct MacDeviceSheet<Content: View>: View {
        let title: LocalizedStringKey
        @ViewBuilder let content: () -> Content
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.m) {
                Text(title)
                    .font(DS.Font.labelEmphasis)
                content()
                    .frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                }
            }
            .padding(DS.Padding.xl)
            .frame(width: 480, height: 320)
            .fittedSheet()
        }
    }

    private extension View {
        /// A popover stays one inside the device sheet: the sheet is narrow
        /// enough to read as compact, and a compact popover becomes a
        /// centred sheet of its own.
        @ViewBuilder
        func keepsPopover() -> some View {
            if #available(macCatalyst 16.4, *) {
                presentationCompactAdaptation(.popover)
            } else {
                self
            }
        }

        /// The sheet as big as its content: a plain sheet on the Mac is a
        /// fixed form sheet much larger than a short list.
        @ViewBuilder
        func fittedSheet() -> some View {
            if #available(macCatalyst 18.0, *) {
                presentationSizing(.fitted)
            } else {
                self
            }
        }
    }

    /// A dim group title between a table's rows.
    private struct MacTableSectionHeader: View {
        let title: LocalizedStringKey

        var body: some View {
            Text(title)
                .font(DS.Font.detail)
                .foregroundColor(.secondary)
                .padding(.horizontal, DS.Padding.m)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
    }

    /// The strip under a table that holds its + button, as AppKit's
    /// gradient-button bar does.
    private let macTableBarHeight: CGFloat = 28

    private struct MacTableBar<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            HStack(spacing: 0) {
                content()
                    .buttonStyle(.borderless)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, DS.Padding.xs)
            .frame(height: macTableBarHeight)
            .background(Color(.secondarySystemBackground).opacity(0.5))
        }
    }

#endif
