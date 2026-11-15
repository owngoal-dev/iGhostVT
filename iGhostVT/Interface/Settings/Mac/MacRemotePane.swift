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
        @ObservedObject private var versions = RemoteHostVersions.shared
        @ObservedObject private var updates = HostUpdateBatch.shared

        @State private var name = RemoteDeviceIdentity.chosenName ?? ""
        @State private var selectedAllowedID: String?
        /// The Accessible Devices rows selected: a click picks one, ⌘
        /// adds or takes one away, ⇧ runs from the last one clicked.
        @State private var selectedHostIDs: Set<String> = []
        @State private var selectionAnchor: String?
        @State private var isShowingPairingCode = false
        @State private var pairingHost: DiscoveredRemoteHost?
        @State private var renamingHostID: String?
        @State private var isRefreshing = false
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
                } footer: {
                    updateBar
                }
                .onAppear {
                    versions.probe(directory.paired.map(\.id))
                }
                .onDisappear {
                    updates.clearSettled()
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
        /// one more, a row's trash takes one away.
        private var allowedDevices: some View {
            MacTableFrame {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.status.devices.enumerated()), id: \.element.id) { index, device in
                                MacDeviceRow(
                                    name: device.name,
                                    address: nil,
                                    index: index,
                                    isSelected: device.id == selectedAllowedID,
                                    select: { selectedAllowedID = device.id },
                                ) {
                                    Text(verbatim: RemoteAccessView.lastSeenText(device))
                                } accessory: {
                                    MacRowIconButton(symbol: "trash", label: "Remove", isSelected: device.id == selectedAllowedID) {
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
                        Button(action: refresh) {
                            Group {
                                if isRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Refresh")
                        .disabled(isRefreshing)
                    }
                }
            }
        }

        /// Asks the helper for its devices again, and looks for the other
        /// devices again while at it.
        private func refresh() {
            isRefreshing = true
            Task {
                async let status: Void = model.refresh()
                await directory.refresh()
                await status
                isRefreshing = false
            }
        }

        // MARK: - The other devices

        /// The devices this Mac is paired with, then the ones nearby it
        /// could pair with. Every row carries its actions, selected or not, so
        /// the trailing details line up — rename, update and forget for a
        /// paired device, Pair for one nearby.
        private var yourDevices: some View {
            let entries = accessibleEntries
            let order = entries.compactMap { entry -> String? in
                if case let .device(device) = entry { device.id } else { nil }
            }
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
                                accessibleRow(device, order: order)
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

        private func accessibleRow(_ device: AccessibleDevice, order: [String]) -> some View {
            let isSelected = selectedHostIDs.contains(device.id)
            let phase = updates.phases[device.id]
            return MacDeviceRow(
                name: device.name,
                address: device.address,
                index: device.index,
                isSelected: isSelected,
                select: { select(device.id, in: order) },
            ) {
                // What an update is doing replaces where the device is; the
                // version keeps its own column either way.
                HStack(spacing: MacDeviceRowMetrics.spacing) {
                    if let phase {
                        MacUpdatePhaseView(phase: phase, hostName: device.name, isSelected: isSelected, window: window)
                    } else {
                        Text(verbatim: device.detail)
                    }
                    // On every row, blank where nothing is known, so the
                    // details line up down the whole table.
                    MacHostVersionText(entry: versions.entries[device.id], isSelected: isSelected)
                }
            } accessory: {
                Group {
                    switch device.action {
                    case let .forget(host):
                        HStack(spacing: MacDeviceRowMetrics.spacing) {
                            MacRowIconButton(symbol: "pencil", label: "Rename", isSelected: isSelected) {
                                renamingHostID = host.id
                            }
                            .popover(
                                isPresented: Binding(
                                    get: { renamingHostID == host.id },
                                    set: { if !$0 { renamingHostID = nil } },
                                ),
                                arrowEdge: .bottom,
                            ) {
                                MacRenameHostView(host: host) { renamingHostID = nil }
                                    .keepsPopover()
                            }
                            MacRowIconButton(symbol: "icloud.and.arrow.up", label: "Check for Update", isSelected: isSelected) {
                                updates.update([host.id], in: window)
                            }
                            .disabled(phase?.isBusy == true || updates.isAsking)
                            MacRowIconButton(symbol: "trash", label: "Forget", isSelected: isSelected) {
                                confirmForget(host)
                            }
                        }
                    case let .pair(host):
                        Button {
                            pairingHost = host
                        } label: {
                            Text("Pair")
                                .font(DS.Font.labelEmphasis)
                                .foregroundColor(isSelected ? .white : .accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                // As wide as a paired row's three buttons, so a nearby
                // device's detail lines up with the paired ones above it.
                .frame(minWidth: MacRowIconButton.width * 3 + MacDeviceRowMetrics.spacing * 2, alignment: .trailing)
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

        /// A table's selection, the Finder's way: a click picks the row, ⌘
        /// adds or takes it away, ⇧ selects from the last row clicked to
        /// this one.
        private func select(_ id: String, in order: [String]) {
            let modifiers = MacEventModifiers.current
            if modifiers.contains(.command) {
                if selectedHostIDs.contains(id) {
                    selectedHostIDs.remove(id)
                } else {
                    selectedHostIDs.insert(id)
                }
                selectionAnchor = id
            } else if modifiers.contains(.shift),
                      let anchor = selectionAnchor,
                      let from = order.firstIndex(of: anchor),
                      let to = order.firstIndex(of: id)
            {
                selectedHostIDs = Set(order[min(from, to) ... max(from, to)])
            } else {
                selectedHostIDs = [id]
                selectionAnchor = id
            }
        }

        /// The selected devices an update can be asked of: paired, and not
        /// already updating.
        private var updatableSelection: [String] {
            directory.paired.map(\.id).filter { id in
                selectedHostIDs.contains(id) && updates.phases[id]?.isBusy != true
            }
        }

        /// Under the table: how the updates under way are going, and the
        /// button that updates every selected device.
        private var updateBar: some View {
            HStack(spacing: DS.Padding.m) {
                if updates.isBusy {
                    MacUpdateProgressSummary(updates: updates)
                } else if directory.paired.count > 1 {
                    Text("Hold ⌘ or ⇧ to select more than one device.")
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Padding.m)
                Button("Check for Updates") {
                    updates.update(updatableSelection, in: window)
                }
                .disabled(updatableSelection.isEmpty || updates.isAsking)
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
                        selectedHostIDs.remove(host.id)
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

    private enum MacDeviceRowMetrics {
        /// Between the detail and the first button, and between buttons:
        /// one gap, so the trailing end reads as one evenly spaced run.
        static var spacing: CGFloat {
            DS.Padding.s
        }
    }

    /// One row of a device table: the name with its address dim after it,
    /// a dim trailing detail, then the row's actions — there on every row,
    /// selected or not, so the details line up — striped, the selection in
    /// the accent.
    private struct MacDeviceRow<Detail: View, Accessory: View>: View {
        let name: String
        let address: String?
        let index: Int
        let isSelected: Bool
        let select: () -> Void
        @ViewBuilder let detail: () -> Detail
        @ViewBuilder let accessory: () -> Accessory

        var body: some View {
            HStack(spacing: MacDeviceRowMetrics.spacing) {
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
                detail()
                    .font(DS.Font.detail)
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                accessory()
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

    /// The version a paired device runs, in a column of its own: dim, or in
    /// the accent with an arrow when it is a Mac that updates itself and
    /// runs an older iGhostVT than this one. Blank until the device has
    /// said.
    private struct MacHostVersionText: View {
        let entry: RemoteHostVersions.Entry?
        let isSelected: Bool

        static let width: CGFloat = 76

        var body: some View {
            HStack(spacing: 3) {
                if let entry {
                    if isBehind(entry) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(isSelected ? .white : .accentColor)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: entry.version)
                        .monospacedDigit()
                        .foregroundColor(isBehind(entry) && !isSelected ? .accentColor : nil)
                }
            }
            .frame(width: Self.width, alignment: .trailing)
            .accessibilityHidden(entry == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry == nil ? Text(verbatim: "") : Text("Version"))
            .accessibilityValue(Text(verbatim: entry?.version ?? ""))
        }

        private func isBehind(_ entry: RemoteHostVersions.Entry) -> Bool {
            entry.updatesItself == true && UpdateCheck.isVersion(RemoteAccess.appVersion, newerThan: entry.version)
        }
    }

    /// How a device's update is going, where its whereabouts were: a
    /// spinner or a bar while it moves, the outcome once it stopped. An
    /// outcome with more to say (why it failed, why it cannot update)
    /// opens it in an alert.
    private struct MacUpdatePhaseView: View {
        let phase: HostUpdateBatch.Phase
        let hostName: String
        let isSelected: Bool
        let window: UIWindow?

        var body: some View {
            switch phase {
            case .checking:
                spinning(Text("Checking…"))
            case let .upToDate(version):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text("Up to date")
                }
                .help(Text("iGhostVT \(version) is the latest version."))
            case let .available(version):
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                    Text("\(version) available")
                }
                .foregroundColor(isSelected ? .white : .accentColor)
            case let .unsupported(message):
                explained(
                    Text("Can’t update from here"),
                    symbol: "info.circle",
                    title: String(localized: "Updates Not Available"),
                    message: message,
                )
            case let .downloading(version, fraction):
                HStack(spacing: 6) {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(isSelected ? .white : .accentColor)
                        .frame(width: 96)
                    Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Downloading iGhostVT \(version)"))
            case .verifying:
                spinning(Text("Verifying…"))
            case .installing:
                spinning(Text("Installing…"))
            case .restarting:
                spinning(Text("Restarting…"))
            case let .updated(version):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(isSelected ? .white : .green)
                    Text("Updated to \(version)")
                }
            case let .unconfirmed(version):
                explained(
                    Text("Update sent (status)"),
                    symbol: "info.circle",
                    title: String(localized: "Update Sent"),
                    message: String(localized: "\(hostName) stopped answering while it installed iGhostVT \(version). It is most likely restarting iGhostVT; open new terminals once it is back."),
                )
            case let .failed(message):
                explained(
                    Text("Failed"),
                    symbol: "exclamationmark.triangle.fill",
                    title: String(localized: "Unable to Install the Update"),
                    message: message,
                    tint: isSelected ? .white : .red,
                )
            }
        }

        private func spinning(_ label: Text) -> some View {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                label
            }
        }

        /// The outcome as a borderless button that says the rest.
        private func explained(_ label: Text, symbol: String, title: String, message: String, tint: Color? = nil) -> some View {
            Button {
                AlertViewController(
                    content: AlertViewController.Content(title: title, message: message),
                    actions: [AlertAction("Done", kind: .highlighted) {}],
                ).present(in: window)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    label
                }
                .foregroundColor(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(message.isEmpty)
        }
    }

    /// Beside the button while updates run: one bar for all of them — how
    /// far the installs have come, or moving while the devices still check
    /// — what they are doing, and Cancel while there is something it can
    /// still stop.
    private struct MacUpdateProgressSummary: View {
        @ObservedObject var updates: HostUpdateBatch

        var body: some View {
            HStack(spacing: DS.Padding.s) {
                Group {
                    if let fraction = updates.overallFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 140)
                Text(title)
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if updates.isCancellable {
                    Button("Cancel") { updates.cancel() }
                        .buttonStyle(.borderless)
                        .font(DS.Font.detail)
                }
            }
        }

        private var title: String {
            let count = updates.installingCount
            if count > 0 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Updating %lld devices…", comment: "Under the Accessible Devices table, beside one progress bar for every paired Mac installing an update"),
                    count,
                )
            }
            return String(localized: "Checking for Updates…")
        }
    }

    /// The modifier keys held right now, read from AppKit (`NSEvent`
    /// through the runtime): a SwiftUI tap does not say which were down.
    private enum MacEventModifiers {
        static var current: UIKeyModifierFlags {
            guard let event = NSClassFromString("NSEvent") as? NSObject.Type,
                  let raw = event.value(forKey: "modifierFlags") as? UInt
            else { return [] }
            // AppKit's flags and UIKit's share their bits.
            return UIKeyModifierFlags(rawValue: Int(raw))
        }
    }

    /// A glyph button on a row: white on the selection's accent, dim
    /// elsewhere.
    private struct MacRowIconButton: View {
        static let width: CGFloat = 18

        let symbol: String
        let label: LocalizedStringKey
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: Self.width, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }

    /// A paired device's name here, edited in a popover off its row's
    /// pencil: blank goes back to the name the device gives itself.
    private struct MacRenameHostView: View {
        let host: PairedRemoteHost
        let done: () -> Void
        @State private var nickname: String

        init(host: PairedRemoteHost, done: @escaping () -> Void) {
            self.host = host
            self.done = done
            _nickname = State(initialValue: host.nickname ?? "")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                TextField(host.name, text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(width: 240)
                    .onSubmit(done)
                Text("Leave this empty to use the name set on the device.")
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Done", action: done)
                }
            }
            .padding(DS.Padding.m)
            // However it closes — Done, Return, or a click outside.
            .onDisappear(perform: save)
        }

        private func save() {
            guard nickname != (host.nickname ?? "") else { return }
            PairedRemoteHostStore.setNickname(nickname, forHostID: host.id)
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
    /// the sheet, then whatever the list adds before Done. Wide enough for a
    /// row's name, its whereabouts or an update's progress, its version and
    /// its buttons side by side, and tall enough for a dozen devices.
    private struct MacDeviceSheet<Content: View, Footer: View>: View {
        let title: LocalizedStringKey
        @ViewBuilder let content: () -> Content
        @ViewBuilder let footer: () -> Footer
        @Environment(\.dismiss) private var dismiss

        init(
            title: LocalizedStringKey,
            @ViewBuilder content: @escaping () -> Content,
            @ViewBuilder footer: @escaping () -> Footer,
        ) {
            self.title = title
            self.content = content
            self.footer = footer
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.m) {
                Text(title)
                    .font(DS.Font.labelEmphasis)
                content()
                    .frame(maxHeight: .infinity)
                HStack(spacing: DS.Padding.m) {
                    footer()
                    Button("Done") { dismiss() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(DS.Padding.xl)
            .frame(width: 720, height: 480)
            .fittedSheet()
        }
    }

    extension MacDeviceSheet where Footer == EmptyView {
        init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
            self.init(title: title, content: content) { EmptyView() }
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
