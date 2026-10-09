import Darwin
import Foundation
import XPC

/// `ighostvt-cli remote …`: this device's remote access, over the same
/// management operations Settings ▸ Remote Access sends (`remoteStatus`
/// through `setRelayConfiguration`). Nothing here is new trust — any
/// admitted local peer may already send them — and none of it reaches the
/// network: the helper answers them only from the local daemon.
enum RemoteCommand {
    case status
    case enable(Bool)
    case pair(wait: Bool)
    case endPairing
    case revoke(deviceID: String)
    case rename(String)
    case relay(path: String?)
}

enum RemoteCommands {
    /// How long `on` and `pair` wait for a helper that is starting.
    private static let startTimeout: TimeInterval = 15

    static func run(_ command: RemoteCommand) throws {
        if case let .relay(path) = command {
            return try relay(path: path)
        }
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        switch command {
        case .status:
            printStatus(try status(client))
        case let .enable(enabled):
            let reply = try RemoteStatus(client.request(.setRemoteAccess) {
                xpc_dictionary_set_bool($0, iGhostVTWireKey.enabled, enabled)
            })
            guard enabled else { return printStatus(reply) }
            printStatus(try reconcileRelay(client, waitForHelper(client, reply)))
        case let .pair(wait):
            try pair(client, wait: wait)
        case .endPairing:
            try client.request(.endPairing)
        case let .revoke(deviceID):
            do {
                try client.request(.revokeRemoteDevice) {
                    xpc_dictionary_set_string($0, iGhostVTWireKey.deviceID, deviceID)
                }
            } catch CLIError.refused(.invalidRequest, _) {
                throw CLIError.usage("No paired device with id \(deviceID). Run `ighostvt-cli remote status` to see them.")
            }
        case let .rename(name):
            try client.request(.setHostName) {
                xpc_dictionary_set_string($0, iGhostVTWireKey.hostName, name)
            }
        case .relay:
            break
        }
    }

    // MARK: - Pairing

    private static func pair(_ client: DaemonClient, wait: Bool) throws {
        var current = try status(client)
        guard current.isEnabled else { throw CLIError.remoteAccessOff }
        current = try reconcileRelay(client, waitForHelper(client, current))
        let pairedBefore = Set(current.devices.map(\.id))
        // As the app does: a host that has a relay also takes the pairing
        // through it, under the relay's own attempt limit.
        let throughRelay = !(current.relayFingerprint ?? "").isEmpty
        let opened = try RemoteStatus(client.request(.beginPairing) {
            xpc_dictionary_set_bool($0, iGhostVTWireKey.relayPairing, throughRelay)
        })
        guard let code = opened.pairingCode else { throw CLIError.remoteAccessStuck(opened.failureMessage) }

        // The code alone on standard output, so a script can take it.
        print(code)
        fflush(stdout)
        if let expiresAt = opened.pairingExpiresAt {
            note("Enter this code on the other device before \(clock(expiresAt)).")
        }
        guard wait else { return }

        // A window opened for someone who is waiting closes when they stop.
        let interrupt = closeWindowOnInterrupt()
        defer { interrupt.forEach { $0.cancel() } }
        while true {
            usleep(500_000)
            let now = try status(client)
            if let device = now.devices.first(where: { !pairedBefore.contains($0.id) }) {
                note("Paired with \(device.name) (\(device.id)).")
                return
            }
            // A new code from someone else closed this one as surely as
            // expiry or too many wrong codes did.
            guard now.pairingCode == code else { throw CLIError.pairingClosed }
        }
    }

    private static func closeWindowOnInterrupt() -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                let client = DaemonClient()
                if (try? client.connect()) != nil {
                    _ = try? client.request(.endPairing)
                    client.cancel()
                }
                note("Pairing closed.")
                exit(128 + number)
            }
            source.resume()
            return source
        }
    }

    // MARK: - Relay

    private static func relay(path: String?) throws {
        #if os(macOS)
            guard getuid() != 0 else { throw CLIError.runAsRoot }
            if let path {
                let configuration = try RelayStoreFile.read(from: path)
                try RelayStoreFile.save(configuration)
                note("Relay is now \(configuration.name) at \(configuration.endpointDescription).")
            } else {
                try RelayStoreFile.remove()
                note("Relay removed.")
            }
            // The file is the setting; the helper is only brought to it.
            // A helper that is not running takes it the next time `remote on`
            // or the app looks.
            let client = DaemonClient()
            guard (try? client.connect()) != nil else {
                note("iGhostVT hands it to its helper once remote access is on.")
                return
            }
            defer { client.cancel() }
            let current = try status(client)
            guard current.relayFingerprint != nil else {
                note("It is used once remote access is on.")
                return
            }
            _ = try reconcileRelay(client, current)
        #else
            _ = path
            throw CLIError.relayUnsupported
        #endif
    }

    /// Brings the helper to the relay the app has, as Settings does on every
    /// status: when the helper's fingerprint differs, the app's file — or
    /// none — is sent. On the device the CLI cannot read the app's file,
    /// so the app alone does this there.
    private static func reconcileRelay(_ client: DaemonClient, _ current: RemoteStatus) throws -> RemoteStatus {
        #if os(macOS)
            let configuration = RelayStoreFile.load()
            guard let reported = current.relayFingerprint,
                  reported != (configuration?.fingerprint ?? "")
            else { return current }
            let data = configuration?.encoded() ?? Data()
            return try RemoteStatus(client.request(.setRelayConfiguration) { message in
                data.withUnsafeBytes { buffer in
                    xpc_dictionary_set_data(
                        message,
                        iGhostVTWireKey.relay,
                        buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                        buffer.count,
                    )
                }
            })
        #else
            return current
        #endif
    }

    // MARK: - Status

    private static func status(_ client: DaemonClient) throws -> RemoteStatus {
        try RemoteStatus(client.request(.remoteStatus))
    }

    /// Waits out `starting`: the proxy answers for a helper that is still on
    /// its way up, and only the helper can open a pairing window.
    private static func waitForHelper(_ client: DaemonClient, _ initial: RemoteStatus) throws -> RemoteStatus {
        var current = initial
        let deadline = Date().addingTimeInterval(startTimeout)
        while current.isEnabled, current.state == .starting {
            guard Date() < deadline else { throw CLIError.remoteAccessStuck(nil) }
            usleep(250_000)
            current = try status(client)
        }
        guard current.isEnabled else { throw CLIError.remoteAccessOff }
        guard current.state == .listening else { throw CLIError.remoteAccessStuck(current.failureMessage) }
        return current
    }

    private static func printStatus(_ status: RemoteStatus) {
        var lines: [(String, String)] = []
        switch (status.isEnabled, status.state) {
        case (false, _): lines.append(("remote access", "off"))
        case (true, .failed): lines.append(("remote access", "failed: \(status.failureMessage ?? "unknown error")"))
        case (true, let state): lines.append(("remote access", state.rawValue))
        }
        if let hostName = status.hostName { lines.append(("name", hostName)) }
        if let hostID = status.hostID { lines.append(("host id", hostID)) }
        if status.port > 0 { lines.append(("port", String(status.port))) }
        if let appVersion = status.appVersion { lines.append(("version", appVersion)) }
        if status.relayFingerprint != nil {
            switch status.relayState {
            case .off:
                lines.append(("relay", "none"))
            default:
                var text = "\(status.relayName ?? "relay"): \(status.relayState.rawValue)"
                if let message = status.relayMessage, !message.isEmpty { text += " (\(message))" }
                lines.append(("relay", text))
            }
        }
        if let code = status.pairingCode {
            var text = code
            if let expiresAt = status.pairingExpiresAt { text += ", until \(clock(expiresAt))" }
            if status.pairingFailureCount > 0 { text += ", \(status.pairingFailureCount) failed" }
            lines.append(("pairing", text))
        }
        if status.isEnabled, status.state == .listening {
            lines.append(("devices", "\(status.devices.count) paired, \(status.connectedCount) connected"))
        }
        let width = lines.map(\.0.count).max() ?? 0
        for (label, value) in lines {
            print(label + ":" + String(repeating: " ", count: width - label.count + 1) + value)
        }
        guard !status.devices.isEmpty else { return }
        print("")
        var table: [[String]] = [["DEVICE", "NAME", "PAIRED", "LAST SEEN"]]
        for device in status.devices {
            table.append([
                device.id,
                device.name,
                device.pairedAt.map(day) ?? "-",
                device.lastSeen.map(day) ?? "-",
            ])
        }
        printTable(table)
    }

    // MARK: - Formatting

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// What a person reads, on standard error, so standard output carries
    /// only what a script would take.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
