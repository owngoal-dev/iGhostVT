import CryptoKit
import Darwin
import Dispatch
import Foundation
import Network

/// This host at its relay (`Relay/PROTOCOL.md`): one control connection,
/// kept registered for as long as remote access is on and a relay is
/// configured, and a call back to the relay for every connection an app
/// makes to this host through it.
///
/// A call back is spliced into `RemoteService`'s relay listener, a TLS
/// listener of its own on the loopback address, so the connection reaches
/// the same `RemoteClient` a local one does: the TLS, the device proof and
/// everything after it are unchanged, and the relay only ever carried
/// ciphertext. Everything here runs on the service's queue except the
/// splices, which run on a queue of their own.
/// What `RelayLink` needs of the host it registers: `RemoteService`, or a
/// test's stand-in. Everything is asked on `queue`.
protocol RelayLinkHost: AnyObject {
    var queue: DispatchQueue { get }
    var relayHostID: String { get }
    var hostName: String { get }
    /// Where a call back is spliced to; nil while the listener is down.
    var relayListenerPort: UInt16? { get }
    func noteRelayArrival(from address: String?)
}

final class RelayLink: @unchecked Sendable {
    private unowned let service: any RelayLinkHost
    private let queue: DispatchQueue
    let configuration: RelayConfiguration
    private let hostKey: P256.Signing.PrivateKey

    private(set) var state = RelayState.connecting
    /// What went wrong, for the settings page; nil while registered.
    private(set) var message: String?

    private var control: RelayControlConnection?
    private var generation = 0
    private var isStopped = false
    private var retryDelay: TimeInterval = 1
    private var lastHeard = Date()
    private var heartbeat: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?

    /// Calls back being set up, at once: anyone who knows the host id can
    /// ask the relay for one, and each costs a connection here. Requests
    /// past that wait their turn — a window restoring several tabs at once
    /// is not an attack — up to `maximumWaitingCallbacks`; beyond that, and
    /// once a request is older than the relay keeps its ticket, they are
    /// dropped.
    private var callbacksInFlight = 0
    private static let maximumCallbacksInFlight = 4
    private var waitingCallbacks: [(ticket: String, from: String?, at: Date)] = []
    private static let maximumWaitingCallbacks = 32
    private static let ticketLifetime: TimeInterval = 10
    /// How often the host pings the relay, and how long it waits for the
    /// pong before it registers again. TCP keepalive notices a link that
    /// went dark, but not a relay behind a proxy that answers keepalive on
    /// its behalf (a published container port is one): only an answer from
    /// the relay itself proves the registration. The ping also keeps a NAT
    /// from forgetting the mapping. A minute, not less: a phone hosting on
    /// a cellular network pays for every wakeup. Settable for tests.
    nonisolated(unsafe) static var pingInterval: TimeInterval = 60
    nonisolated(unsafe) static var pongTimeout: TimeInterval = 20
    private static let maximumRetryDelay: TimeInterval = 60

    let spliceQueue = DispatchQueue(label: "wiki.qaq.ighostvt.remote.relay", qos: .userInitiated)

    init(service: any RelayLinkHost, configuration: RelayConfiguration, hostKey: Data) throws {
        self.service = service
        queue = service.queue
        self.configuration = configuration
        self.hostKey = try P256.Signing.PrivateKey(rawRepresentation: hostKey)
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(path)
        }
        pathMonitor.start(queue: queue)
        connect()
    }

    func stop() {
        isStopped = true
        generation += 1
        pathMonitor.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        control?.close()
        control = nil
    }

    /// Registers again — the host's name changed and the relay's list
    /// should say so.
    func register() {
        guard !isStopped, state == .registered || state == .connecting || state == .failed else { return }
        retryDelay = 1
        connect()
    }

    // MARK: - Registration

    private func connect() {
        control?.close()
        heartbeat?.cancel()
        heartbeat = nil
        generation += 1
        let generation = generation
        state = .connecting
        let control = RelayControlConnection(configuration: configuration, queue: queue)
        self.control = control
        control.start { [weak self] ready in
            guard let self, generation == self.generation else { return }
            if case let .failure(error) = ready {
                return failed(error)
            }
            control.receiveHello(expecting: configuration.relayID) { [weak self] hello in
                guard let self, generation == self.generation else { return }
                switch hello {
                case let .failure(error):
                    failed(error)
                case let .success(nonce):
                    sendRegistration(over: control, nonce: nonce, generation: generation)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, generation == self.generation, state == .connecting else { return }
            failed(.unreachable("no answer in 15 s"))
        }
    }

    private func sendRegistration(over control: RelayControlConnection, nonce: String, generation: Int) {
        let hostID = service.relayHostID
        let signed = RelayControl.signedMessage(
            role: .host,
            relayID: configuration.relayID,
            nonce: nonce,
            parameter: hostID,
        )
        guard let signature = RelayControl.sign(signed, with: configuration.signingKey),
              let hostSignature = RelayControl.sign(signed, with: hostKey)
        else { return failed(.malformed("could not sign")) }
        control.send([
            "role": RelayControl.Role.host.rawValue,
            "hostID": hostID,
            "name": service.hostName,
            "appVersion": RemoteAccess.wireVersion,
            "hostKey": hostKey.publicKey.derRepresentation.base64EncodedString(),
            "sig": signature,
            "hostSig": hostSignature,
        ])
        control.receiveAnswer { [weak self] answer in
            guard let self, generation == self.generation else { return }
            switch answer {
            case let .failure(error):
                failed(error)
            case .success:
                state = .registered
                message = nil
                retryDelay = 1
                lastHeard = Date()
                RemoteLog.log("registered with relay \(configuration.name) at \(configuration.endpointDescription)")
                startHeartbeat(generation: generation)
                readFrames(from: control, generation: generation)
            }
        }
    }

    private func readFrames(from control: RelayControlConnection, generation: Int) {
        control.receiveFrame { [weak self] result in
            guard let self, generation == self.generation else { return }
            switch result {
            case let .failure(error):
                failed(error)
            case let .success(frame):
                lastHeard = Date()
                switch frame["type"] as? String {
                case "incoming":
                    if let ticket = frame["ticket"] as? String {
                        callBack(ticket: ticket, from: frame["from"] as? String)
                    }
                case "ping":
                    control.send(["type": "pong"])
                case "superseded":
                    // Another machine has this host's identity and key — a
                    // copied state file. Reconnecting would push it off,
                    // and it would push back, for ever.
                    stopRetrying(
                        .conflict,
                        "Another device registered at the relay as this one. It may be a copy of this device; remote access there needs a fresh identity.",
                    )
                    RemoteLog.log("relay: another device took over this host's registration")
                    return
                default:
                    break
                }
                readFrames(from: control, generation: generation)
            }
        }
    }

    private func startHeartbeat(generation: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.generation, let control else { return }
            let sentAt = Date()
            control.send(["type": "ping"])
            queue.asyncAfter(deadline: .now() + Self.pongTimeout) { [weak self] in
                guard let self, generation == self.generation, lastHeard < sentAt else { return }
                failed(.unreachable("no answer from the relay in \(Int(Self.pongTimeout)) s"))
            }
        }
        heartbeat = timer
        timer.activate()
    }

    private func failed(_ error: RelayError) {
        guard !isStopped else { return }
        control?.close()
        control = nil
        heartbeat?.cancel()
        heartbeat = nil
        switch error {
        case let .version(relay):
            RemoteLog.log("relay speaks protocol \(relay), this host \(RelayControl.protocolVersion)")
            return stopRetrying(
                .versionMismatch,
                "The relay runs another version (protocol \(relay); this device needs \(RelayControl.protocolVersion)). Update the relay or iGhostVT so they match.",
            )
        case .refused("hostKey"):
            RemoteLog.log("relay: this host id belongs to another host key")
            return stopRetrying(
                .conflict,
                "The relay knows this device by another key. Ask its owner to run “ighostvt-relay forget” for this device.",
            )
        case .refused("auth"), .refused("relayID"):
            message = "The relay did not accept this configuration. Import the current one from the relay."
        case .refused("full"):
            message = "The relay has as many devices as it allows."
        case let .unreachable(reason):
            message = "Unable to reach the relay."
            RemoteLog.log("relay \(configuration.endpointDescription): \(reason)")
        case let .refused(reason), let .malformed(reason):
            message = "The relay refused this device (\(reason))."
        }
        state = .failed
        let jitter = Double.random(in: 0.8 ... 1.2)
        let delay = retryDelay * jitter
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        let generation = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !isStopped, generation == self.generation, state == .failed else { return }
            connect()
        }
    }

    private func stopRetrying(_ state: RelayState, _ message: String) {
        generation += 1
        control?.close()
        control = nil
        heartbeat?.cancel()
        heartbeat = nil
        self.state = state
        self.message = message
    }

    /// Another network: the control connection most likely died with the
    /// old one, and waiting for keepalive to say so costs half a minute.
    private func pathChanged(_ path: NWPath) {
        let signature = path.status == .satisfied
            ? path.availableInterfaces.map(\.name).joined(separator: ",")
            : "unsatisfied"
        defer { lastPathSignature = signature }
        guard let previous = lastPathSignature, previous != signature, path.status == .satisfied,
              !isStopped, state != .conflict, state != .versionMismatch
        else { return }
        RemoteLog.log("network changed, registering with the relay again")
        retryDelay = 1
        connect()
    }

    // MARK: - Calls back

    /// An app wants this host: dial the relay, claim the ticket, and splice
    /// the stream into the relay listener.
    private func callBack(ticket: String, from: String?) {
        guard waitingCallbacks.count < Self.maximumWaitingCallbacks else {
            RemoteLog.log("relay: dropped a connection request, \(waitingCallbacks.count) waiting")
            return
        }
        waitingCallbacks.append((ticket, from, Date()))
        startWaitingCallbacks()
    }

    private func startWaitingCallbacks() {
        while callbacksInFlight < Self.maximumCallbacksInFlight, !waitingCallbacks.isEmpty {
            let next = waitingCallbacks.removeFirst()
            guard Date().timeIntervalSince(next.at) < Self.ticketLifetime else { continue }
            startCallBack(ticket: next.ticket, from: next.from)
        }
    }

    private func startCallBack(ticket: String, from: String?) {
        guard let port = service.relayListenerPort else {
            RemoteLog.log("relay: dropped a connection request, the relay listener is not up")
            return
        }
        let message = RelayControl.signedMessage(role: .accept, relayID: configuration.relayID, nonce: "", parameter: ticket)
        guard let signature = RelayControl.sign(message, with: hostKey) else { return }
        callbacksInFlight += 1
        let control = RelayControlConnection(configuration: configuration, queue: spliceQueue)
        let finished = Once { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.callbacksInFlight -= 1
                self.startWaitingCallbacks()
            }
        }
        spliceQueue.asyncAfter(deadline: .now() + 15) {
            if finished.run() {
                control.close()
            }
        }
        let relayID = configuration.relayID
        let spliceQueue = spliceQueue
        control.start { [weak self] ready in
            let link = self
            guard case .success = ready else {
                if finished.run() { control.close() }
                return
            }
            // The ticket is fresh on its own: the claim goes out with the
            // opening, not after the relay's challenge.
            control.send(["role": RelayControl.Role.accept.rawValue, "ticket": ticket, "hostSig": signature])
            control.receiveHello(expecting: relayID) { hello in
                guard case .success = hello else {
                    if finished.run() { control.close() }
                    return
                }
                control.receiveAnswer { answer in
                    guard case .success = answer else {
                        // The app went away, or the ticket did: nothing to
                        // splice, and nothing reaches the listener.
                        if finished.run() { control.close() }
                        return
                    }
                    let relayed = control.detach()
                    link?.queue.async {
                        link?.service.noteRelayArrival(from: from)
                    }
                    let loopback = NWConnection(
                        host: "127.0.0.1",
                        port: NWEndpoint.Port(rawValue: port) ?? .any,
                        using: .tcp,
                    )
                    let splice = RelaySplice(relayed, loopback, queue: spliceQueue)
                    splice.onSettled = { _ in _ = finished.run() }
                    splice.start()
                }
            }
        }
    }
}

/// Two connections, each one's bytes written to the other, until either
/// ends — then both end, nothing left half open. A read waits for the write
/// before it, so a side that does not read slows the side that writes
/// instead of filling memory here.
final class RelaySplice {
    private let first: NWConnection
    private let second: NWConnection
    private let queue: DispatchQueue
    private var isEnded = false
    /// Once: true when both sides are up, false when it ended before that.
    var onSettled: ((Bool) -> Void)?
    /// Holds itself while running: nothing else does.
    private var retained: RelaySplice?
    private var lastActivity = Date()

    private static let chunkByteCount = 64 * 1024
    /// A device pings a quiet link every `RemoteAccess.linkPingInterval`,
    /// so a splice that carried nothing for this long is dead end to end,
    /// whatever TCP says — a proxy on the way keeps answering keepalive
    /// for a relay that is gone.
    static let idleLimit = RemoteAccess.deviceSilenceLimit + 15

    /// `first` is already started (on `queue`); `second` is not.
    init(_ first: NWConnection, _ second: NWConnection, queue: DispatchQueue) {
        self.first = first
        self.second = second
        self.queue = queue
    }

    func start() {
        retained = self
        first.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        second.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                settle(true)
                pump(from: first, to: second)
                pump(from: second, to: first)
                watchIdle()
            }
            stateChanged(state)
        }
        second.start(queue: queue)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled, .waiting:
            end()
        default:
            break
        }
    }

    private func settle(_ isUp: Bool) {
        let settled = onSettled
        onSettled = nil
        settled?(isUp)
    }

    private func watchIdle() {
        queue.asyncAfter(deadline: .now() + Self.idleLimit / 4) { [weak self] in
            guard let self, !isEnded else { return }
            if Date().timeIntervalSince(lastActivity) > Self.idleLimit {
                end()
            } else {
                watchIdle()
            }
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkByteCount) { [weak self] data, _, isComplete, error in
            guard let self, !isEnded else { return }
            lastActivity = Date()
            let finishAfter = isComplete || error != nil
            guard let data, !data.isEmpty else {
                return finishAfter ? end() : pump(from: source, to: destination)
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !isEnded else { return }
                if sendError != nil || finishAfter {
                    end()
                } else {
                    pump(from: source, to: destination)
                }
            })
        }
    }

    private func end() {
        guard !isEnded else { return }
        isEnded = true
        settle(false)
        first.stateUpdateHandler = nil
        second.stateUpdateHandler = nil
        // Reset, not a graceful close: a graceful one waits for what is
        // queued to leave, and when the side it is queued for is itself
        // stuck writing to us — a host echoing a flood — neither ever
        // drains, and the connection on the host stays open for good.
        first.forceCancel()
        second.forceCancel()
        retained = nil
    }
}

/// A closure that runs at most once, from any thread. `run` says whether
/// this call was the one.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    @discardableResult
    func run() -> Bool {
        lock.lock()
        let body = body
        self.body = nil
        lock.unlock()
        body?()
        return body != nil
    }
}
