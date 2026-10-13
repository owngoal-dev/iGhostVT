import Dispatch
import Foundation
import Network
import XPC

/// Where the command's requests go: `--host`, else this device's daemon.
enum DaemonTarget {
    /// The `--host` given, or `IGHOSTVT_HOST`; nil for this device.
    nonisolated(unsafe) static var hostSelector: String?

    static func connect() throws -> DaemonRequester {
        guard let selector = hostSelector else {
            let client = DaemonClient()
            try client.connect()
            return client
        }
        try AppFiles.requireUser()
        let host = try HostSelector.resolve(selector, in: PairedHostFile.read(at: AppFiles.pairedHostsURL).hosts)
        return try RemoteDaemonClient.connect(to: host)
    }
}

/// A paired host's daemon, through its `ighostvtd-remote`, for one command:
/// the app's remote link (`RemoteDaemonLink`) cut down to what a program
/// that asks a few questions and exits needs — no heartbeat, no reconnect,
/// no events, since it attaches to nothing.
///
/// The same TLS as the app's, under the app's device key for that host,
/// and the same hello with the same proof: to the host this is the app's
/// device, and every operation it may send is one the app already sends.
/// The host is tried at the address it last answered at, at the address
/// Bonjour finds for it, and through the app's relay a moment later; the
/// first handshake to finish is the link.
final class RemoteDaemonClient: DaemonRequester {
    private static let connectTimeout: TimeInterval = 15
    /// A remote host's answer crosses a relay and maybe a slow link; a
    /// snapshot carries the whole replay.
    private static let requestTimeout: TimeInterval = 30
    /// How long Bonjour has to find the host on this network before only
    /// the paths already dialled are waited on.
    private static let browseWindow: TimeInterval = 1.5
    /// The relay's head start given to a direct path that may answer.
    private static let relayDelay: TimeInterval = 0.3

    private let host: PairedRemoteHost
    private let relay: RelayConfiguration?
    private let deviceName: String?
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.cli.remote")

    // Everything below is used on `queue` only.
    private var frames: RemoteFrameConnection?
    private var attempts: [RemoteFrameConnection] = []
    private var failures: [String] = []
    private var browser: NWBrowser?
    private var dialledBonjour = false
    private var relayStarted = false
    private var browseOver = false
    private var connectDone: DispatchSemaphore?
    private var connectFailed = false
    private var pending: [UInt64: (xpc_object_t?) -> Void] = [:]
    private var nextTag: UInt64 = 1
    private var closedReason: String?

    private init(host: PairedRemoteHost) {
        self.host = host
        relay = AppFiles.relay()
        deviceName = AppFiles.deviceName()
    }

    static func connect(to host: PairedRemoteHost) throws -> RemoteDaemonClient {
        let client = RemoteDaemonClient(host: host)
        try client.open()
        do {
            try client.request(.hello)
        } catch {
            client.cancel()
            throw error
        }
        return client
    }

    // MARK: - Connecting

    private func open() throws {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            connectDone = done
            start()
        }
        let answered = done.wait(timeout: .now() + Self.connectTimeout) == .success
        let failures = queue.sync { () -> [String]? in
            guard answered, !connectFailed, frames != nil else {
                connectDone = nil
                stopTrying()
                return self.failures
            }
            return nil
        }
        if let failures {
            throw CLIError.hostUnreachable(host.displayName, failures)
        }
    }

    private func start() {
        if let endpoint = host.lastEndpoint {
            dial(endpoint, label: "\(host.lastAddress ?? "") directly")
        }
        browse()
        if relay != nil {
            if attempts.isEmpty {
                startRelay()
            } else {
                queue.asyncAfter(deadline: .now() + Self.relayDelay) { [self] in startRelay() }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.browseWindow) { [self] in
            browseOver = true
            checkExhausted()
        }
    }

    private func browse() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteAccess.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !dialledBonjour, frames == nil else { return }
            for result in results {
                guard case let .bonjour(record) = result.metadata,
                      record[RemoteAccess.TXTKey.hostID] == host.id
                else { continue }
                dialledBonjour = true
                dial(result.endpoint, label: "on this network")
                return
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func startRelay() {
        guard !relayStarted, frames == nil, connectDone != nil, let relay else { return }
        relayStarted = true
        dial(relay.endpoint, label: "through the relay")
    }

    private func dial(_ endpoint: NWEndpoint, label: String) {
        let parameters = RemoteTLS.parameters(
            keys: [RemoteTLS.Key(identity: Data(host.deviceID.utf8), secret: host.deviceKey)],
            serverName: host.id,
        )
        RemoteNetwork.keepOnLocalNetwork(parameters, to: endpoint)
        let attempt = RemoteFrameConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
        attempt.acceptsCompressedInput = true
        attempt.onReady = { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            won(attempt)
        }
        attempt.onFrame = { [weak self] header, object in
            guard header.kind == .reply else { return }
            self?.pending.removeValue(forKey: header.tag)?(object)
        }
        attempt.onClosed = { [weak self, weak attempt] reason in
            guard let self, let attempt else { return }
            closed(attempt, label: label, reason: reason)
        }
        attempts.append(attempt)
        attempt.start()
    }

    private func won(_ winner: RemoteFrameConnection) {
        guard frames == nil, let done = connectDone else { return }
        frames = winner
        attempts.removeAll { $0 === winner }
        stopTrying()
        connectDone = nil
        done.signal()
    }

    private func closed(_ attempt: RemoteFrameConnection, label: String, reason: String) {
        if attempt === frames {
            closedReason = reason
            let unanswered = pending
            pending.removeAll()
            for reply in unanswered.values {
                reply(nil)
            }
            return
        }
        attempts.removeAll { $0 === attempt }
        failures.append("\(label): \(reason)")
        // No point waiting out the head start of a path that is gone.
        startRelay()
        checkExhausted()
    }

    /// Every path tried has failed and none is left to try.
    private func checkExhausted() {
        guard frames == nil, let done = connectDone, attempts.isEmpty, browseOver,
              relay == nil || relayStarted
        else { return }
        connectFailed = true
        connectDone = nil
        done.signal()
    }

    private func stopTrying() {
        browser?.cancel()
        browser = nil
        for attempt in attempts {
            attempt.onClosed = nil
            attempt.close(reason: "another path answered first")
        }
        attempts.removeAll()
    }

    // MARK: - Requests

    @discardableResult
    func request(_ operation: iGhostVTOperation, _ fill: (xpc_object_t) -> Void) throws -> xpc_object_t {
        let message = DaemonClient.message(operation, fill)
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        let tag = queue.sync { () -> UInt64 in
            let tag = nextTag
            nextTag &+= 1
            guard let frames, closedReason == nil else {
                done.signal()
                return tag
            }
            if operation == .hello, !prepareHello(message, over: frames) {
                done.signal()
                return tag
            }
            pending[tag] = { reply in
                box.reply = reply
                done.signal()
            }
            if !frames.send(.request, tag: tag, object: message) {
                pending.removeValue(forKey: tag)
                done.signal()
            }
            return tag
        }
        guard done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            queue.sync { _ = pending.removeValue(forKey: tag) }
            throw CLIError.hostTimedOut(host.displayName)
        }
        guard let reply = box.reply, xpc_get_type(reply) == iGhostVTXPC.typeDictionary else {
            throw CLIError.hostLost(host.displayName)
        }
        return try DaemonClient.checked(
            reply,
            unreachable: .hostLost(host.displayName),
            versionMismatch: .hostVersion(host.displayName, DaemonClient.string(reply, iGhostVTWireKey.appVersion) ?? ""),
        )
    }

    /// The hello says which device this is and proves it, over this TLS
    /// session, exactly as the app's does.
    private func prepareHello(_ message: xpc_object_t, over frames: RemoteFrameConnection) -> Bool {
        guard let exporter = RemoteTLS.exporterSecret(of: frames.connection) else { return false }
        let proof = RemoteDeviceProof.make(key: host.deviceKey, exporterSecret: exporter, deviceID: host.deviceID)
        xpc_dictionary_set_string(message, iGhostVTWireKey.deviceID, host.deviceID)
        if let deviceName {
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceName, deviceName)
        }
        xpc_dictionary_set_string(message, iGhostVTWireKey.appVersion, RemoteAccess.wireVersion)
        // A snapshot's replay is the frame that compresses.
        RemoteFrameCompression.offer(in: message)
        proof.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, iGhostVTWireKey.confirmation, base, buffer.count)
            }
        }
        return true
    }

    func cancel() {
        queue.sync {
            stopTrying()
            connectDone = nil
            frames?.onClosed = nil
            frames?.close(reason: "done")
            frames = nil
        }
    }
}

/// A reply handed from the link's queue to the waiting thread; the
/// semaphore orders the two.
private final class ReplyBox: @unchecked Sendable {
    var reply: xpc_object_t?
}
