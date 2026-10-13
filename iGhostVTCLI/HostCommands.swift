import CryptoKit
import Darwin
import Dispatch
import Foundation
import Network
import XPC

/// `hosts` and `pair`: the hosts this device is paired with — the app's
/// own list, which the CLI shares — and pairing with another one, which
/// the app then lists too.
enum HostCommands {
    static func list() throws {
        try AppFiles.requireUser()
        let hosts = PairedHostFile.read(at: AppFiles.pairedHostsURL).hosts
        guard !hosts.isEmpty else { return }
        var table: [[String]] = [["NAME", "HOST", "ADDRESS", "PAIRED", "LAST SEEN"]]
        for host in hosts {
            table.append([
                host.displayName,
                host.id,
                host.lastAddress ?? "-",
                RemoteCommands.day(host.pairedAt),
                host.lastSeen.map(RemoteCommands.day) ?? "-",
            ])
        }
        printTable(table)
    }

    static func nearby() throws {
        try AppFiles.requireUser()
        let found = HostDiscovery.discover()
        guard !found.isEmpty else { return }
        let paired = Set(PairedHostFile.read(at: AppFiles.pairedHostsURL).hosts.map(\.id))
        var table: [[String]] = [["NAME", "HOST", "ADDRESS", "VERSION", "VIA", "PAIRED"]]
        for host in found {
            table.append([
                host.name,
                host.id,
                host.address ?? "-",
                host.appVersion ?? "-",
                host.viaRelay ? "relay" : "local network",
                paired.contains(host.id) ? "yes" : "no",
            ])
        }
        printTable(table)
    }

    /// Pairs with the host `selector` names among those found nearby or at
    /// the relay, with the code it shows (`ighostvt-cli remote pair` there,
    /// or its Settings ▸ Remote Access). Exactly what the app's pairing
    /// does, saved where the app keeps its own.
    static func pair(selector: String, code: String?) throws {
        try AppFiles.requireUser()
        let found = HostDiscovery.discover()
        let host = try choose(selector, among: found)
        // A host that advertises no version is older than the rule.
        guard RemoteAccess.isCompatible(host.appVersion ?? "") else {
            throw CLIError.hostVersion(host.name, host.appVersion ?? "")
        }
        let code = try code ?? readCode(for: host.name)
        guard code.count == RemoteAccess.pairingCodeLength, code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber) else {
            throw CLIError.usage("A pairing code is \(RemoteAccess.pairingCodeLength) digits.")
        }
        let deviceID = AppFiles.deviceID()
        let paired = try PairingLink.pair(with: host, code: code, deviceID: deviceID, deviceName: AppFiles.deviceName())
        let url = AppFiles.pairedHostsURL
        let saved = PairedHostFile.withLock(at: url) { () -> Bool in
            var hosts = PairedHostFile.read(at: url).hosts
            var record = paired
            // Pairing again keeps the name the user gave it.
            record.nickname = hosts.first { $0.id == paired.id }?.nickname
            hosts.removeAll { $0.id == paired.id }
            hosts.append(record)
            return PairedHostFile.write(hosts, at: url) != nil
        }
        guard saved == true else { throw CLIError.hostStoreFailed(url.path) }
        print("Paired with \(paired.name) (\(paired.id)).")
    }

    private static func choose(_ selector: String, among found: [HostDiscovery.Host]) throws -> HostDiscovery.Host {
        let wanted = selector.lowercased()
        let rules: [(HostDiscovery.Host) -> Bool] = [
            { $0.id.lowercased() == wanted },
            { $0.name.lowercased() == wanted },
            { $0.address == selector },
            { wanted.count >= 4 && $0.id.lowercased().hasPrefix(wanted) },
        ]
        for rule in rules {
            let matches = found.filter(rule)
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw CLIError.hostAmbiguous(selector, matches.map { "\($0.name) (\($0.id))" })
            }
        }
        throw CLIError.hostNotFound(selector, found.map(\.name))
    }

    /// The code, typed: nothing on the command line, where it would sit in
    /// the shell's history for the two minutes it works.
    private static func readCode(for name: String) throws -> String {
        if isatty(STDIN_FILENO) != 0 {
            FileHandle.standardError.write(Data("Pairing code shown on \(name): ".utf8))
        }
        guard let line = readLine() else { throw CLIError.usage("No pairing code given.") }
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// The hosts that offer remote access right now: on this network by
/// Bonjour, and at the app's relay. A host in both is listed once, as
/// nearby — that is the path a pairing then takes.
enum HostDiscovery {
    struct Host {
        var id: String
        var name: String
        var address: String?
        var appVersion: String?
        var endpoint: NWEndpoint
        var viaRelay: Bool
    }

    /// Bonjour answers in well under a second on a network that has the
    /// host; the relay is asked at the same time.
    static func discover(window: TimeInterval = 2) -> [Host] {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.cli.discovery")
        var bonjour: [Host] = []
        var relayed: [Host] = []
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteAccess.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            bonjour = results.compactMap(host(from:))
        }
        browser.start(queue: queue)

        let relayAnswered = DispatchSemaphore(value: 0)
        if let relay = AppFiles.relay() {
            RelayControl.listHosts(configuration: relay, timeout: window + 2) { result in
                queue.async {
                    if case let .success(entries) = result {
                        relayed = entries.map {
                            Host(
                                id: $0.id,
                                name: $0.name,
                                address: nil,
                                appVersion: $0.appVersion.isEmpty ? nil : $0.appVersion,
                                endpoint: relay.endpoint,
                                viaRelay: true,
                            )
                        }
                    }
                    relayAnswered.signal()
                }
            }
        } else {
            relayAnswered.signal()
        }
        Thread.sleep(forTimeInterval: window)
        _ = relayAnswered.wait(timeout: .now() + 2)
        return queue.sync {
            browser.cancel()
            let own = AppFiles.ownHostID()
            var seen: Set<String> = []
            return (bonjour + relayed)
                .filter { $0.id != own && seen.insert($0.id).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private static func host(from result: NWBrowser.Result) -> Host? {
        guard case let .bonjour(record) = result.metadata,
              let id = record[RemoteAccess.TXTKey.hostID], !id.isEmpty
        else { return nil }
        var name = record[RemoteAccess.TXTKey.hostName] ?? ""
        if name.isEmpty, case let .service(serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }
        return Host(
            id: id,
            name: name,
            address: record[RemoteAccess.TXTKey.address].flatMap { $0.isEmpty ? nil : $0 },
            appVersion: record[RemoteAccess.TXTKey.appVersion].flatMap { $0.isEmpty ? nil : $0 },
            endpoint: result.endpoint,
            viaRelay: false,
        )
    }
}

/// One pairing, as the app's `RemotePairingClient` runs it: TLS under the
/// public pairing key, SPAKE2+ inside it as the prover, the host's
/// confirmation checked before this side says anything that depends on the
/// code.
private final class PairingLink {
    private static let requestTimeout: TimeInterval = 15

    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.cli.pairing")
    private let frames: RemoteFrameConnection
    private var pending: [UInt64: (xpc_object_t?) -> Void] = [:]
    private var nextTag: UInt64 = 1
    private var isClosed = false

    private init(endpoint: NWEndpoint, hostID: String) {
        let parameters = RemoteTLS.parameters(
            keys: [RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey)],
            serverName: hostID,
        )
        RemoteNetwork.keepOnLocalNetwork(parameters, to: endpoint)
        frames = RemoteFrameConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
        frames.onFrame = { [weak self] header, object in
            guard header.kind == .reply else { return }
            self?.pending.removeValue(forKey: header.tag)?(object)
        }
        frames.onClosed = { [weak self] _ in
            guard let self else { return }
            isClosed = true
            let unanswered = pending
            pending.removeAll()
            for reply in unanswered.values {
                reply(nil)
            }
        }
        queue.async { [frames] in frames.start() }
    }

    static func pair(
        with host: HostDiscovery.Host,
        code: String,
        deviceID: String,
        deviceName: String?,
    ) throws -> PairedRemoteHost {
        let link = PairingLink(endpoint: host.endpoint, hostID: host.id)
        defer { link.close() }
        let exchange: PairingExchange
        do {
            exchange = try PairingExchange(role: .prover, code: code)
        } catch {
            throw CLIError.pairingFailed("Unable to pair. Try again.")
        }

        let start = DaemonClient.message(.pairStart) { message in
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceID, deviceID)
            xpc_dictionary_set_string(
                message,
                iGhostVTWireKey.deviceName,
                RemoteAccess.sanitizedName(deviceName ?? ProcessInfo.processInfo.hostName),
            )
            xpc_dictionary_set_string(message, iGhostVTWireKey.appVersion, RemoteAccess.wireVersion)
        }
        guard let share = try? exchange.makeShare() else { throw CLIError.pairingFailed("Unable to pair. Try again.") }
        set(share, iGhostVTWireKey.share, in: start)
        let answer = try link.request(start, hostName: host.name)
        guard let hostShare = data(iGhostVTWireKey.share, in: answer),
              let hostConfirmation = data(iGhostVTWireKey.confirmation, in: answer),
              let hostID = DaemonClient.string(answer, iGhostVTWireKey.hostID),
              let hostName = DaemonClient.string(answer, iGhostVTWireKey.hostName),
              // The host that answers has to be the one that was listed.
              hostID == host.id, hostID != AppFiles.ownHostID()
        else { throw CLIError.pairingFailed("Unable to pair. Try again.") }

        let sessionKey: SymmetricKey
        do {
            try exchange.receiveShare(hostShare)
            sessionKey = try exchange.verifyConfirmation(hostConfirmation)
        } catch {
            throw CLIError.pairingFailed("Incorrect code. Try again.")
        }
        let finish = DaemonClient.message(.pairFinish) { _ in }
        guard let confirmation = try? exchange.makeConfirmation() else {
            throw CLIError.pairingFailed("Unable to pair. Try again.")
        }
        set(confirmation, iGhostVTWireKey.confirmation, in: finish)
        _ = try link.request(finish, hostName: host.name)

        return PairedRemoteHost(
            id: hostID,
            name: RemoteAccess.sanitizedName(hostName),
            deviceID: deviceID,
            deviceKey: PairingExchange.deviceKey(sessionKey: sessionKey, hostID: hostID, deviceID: deviceID),
            pairedAt: Date(),
            // Through the relay the address that answered is the relay's.
            lastAddress: host.viaRelay ? nil : link.reachedAddress() ?? host.address,
            lastSeen: Date(),
        )
    }

    private func request(_ message: xpc_object_t, hostName: String) throws -> xpc_object_t {
        let done = DispatchSemaphore(value: 0)
        let box = PairingReplyBox()
        queue.sync {
            guard !isClosed else {
                done.signal()
                return
            }
            let tag = nextTag
            nextTag &+= 1
            pending[tag] = { reply in
                box.reply = reply
                done.signal()
            }
            if !frames.send(.request, tag: tag, object: message) {
                pending.removeValue(forKey: tag)
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + Self.requestTimeout) == .success, let reply = box.reply,
              xpc_get_type(reply) == iGhostVTXPC.typeDictionary
        else {
            throw CLIError.hostUnreachable(hostName, [])
        }
        let code = iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code))
        if code == .unsupportedVersion {
            throw CLIError.hostVersion(hostName, DaemonClient.string(reply, iGhostVTWireKey.appVersion) ?? "")
        }
        guard code == .success else {
            throw CLIError.pairingFailed(
                DaemonClient.string(reply, iGhostVTWireKey.errorMessage) ?? "Unable to pair. Try again.",
            )
        }
        return reply
    }

    /// The IPv4 address the pairing reached, to dial back first next time.
    private func reachedAddress() -> String? {
        queue.sync {
            guard case let .hostPort(host, _) = frames.connection.currentPath?.remoteEndpoint else { return nil }
            return RemoteNetwork.ipv4Description(host)
        }
    }

    private func close() {
        queue.sync {
            frames.onClosed = nil
            frames.close(reason: "pairing over")
        }
    }

    private static func set(_ value: Data, _ key: String, in dictionary: xpc_object_t) {
        value.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(dictionary, key, base, buffer.count)
            }
        }
    }

    private static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        withExtendedLifetime(dictionary) {
            var count = 0
            guard let bytes = xpc_dictionary_get_data(dictionary, key, &count) else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }
}

private final class PairingReplyBox: @unchecked Sendable {
    var reply: xpc_object_t?
}
