import CryptoKit
import Darwin
import Dispatch
import Foundation
import Network
@preconcurrency import XPC

// A paired device with no interface, against a real host: the Mac's own
// `ighostvtd-remote`, reached directly or through a relay — usually through
// `Scripts/remote-lab/netem-proxy.py`, which makes the path a bad one. It
// speaks what the app speaks (remote TLS with the host id as SNI, the hello
// proof, the relayed heartbeat) and receives `sz` with the app's own
// `ZmodemEngine`, so a download that fails here fails the same way in a tab.
//
//   remote-lab pair --state DIR --host-id ID --address HOST:PORT --code CODE --version X.Y.Z
//   remote-lab sz   --state DIR --file PATH [--relay FILE [--via HOST:PORT] | --direct HOST:PORT]
//                   [--sz PATH] [--timeout S] [--version X.Y.Z]
//
// `Scripts/remote-lab/lab.sh` drives both; see there for the whole loop.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let started = Date()

func say(_ line: String) {
    print(String(format: "[%7.2f] ", Date().timeIntervalSince(started)) + line)
}

func fail(_ line: String) -> Never {
    say("error: \(line)")
    exit(1)
}

var options: [String: String] = [:]
let command = CommandLine.arguments.dropFirst().first ?? ""
do {
    var rest = Array(CommandLine.arguments.dropFirst(2))
    while !rest.isEmpty {
        let key = rest.removeFirst()
        guard key.hasPrefix("--"), !rest.isEmpty else { fail("bad argument \(key)") }
        options[String(key.dropFirst(2))] = rest.removeFirst()
    }
}

func option(_ name: String) -> String {
    guard let value = options[name] else { fail("--\(name) is required") }
    return value
}

func endpoint(_ text: String) -> NWEndpoint {
    guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else {
        fail("bad address \(text)")
    }
    return .hostPort(host: NWEndpoint.Host(String(text[..<colon])), port: NWEndpoint.Port(rawValue: port)!)
}

/// What the device says it runs: `x.y.0`, as `RemoteAccess.wireVersion`.
let wireVersion: String = {
    let parts = (options["version"] ?? "1.4.0").split(separator: ".")
    return parts.count >= 2 ? "\(parts[0]).\(parts[1]).0" : "1.4.0"
}()

// MARK: - Device state

struct LabDevice: Codable {
    var deviceID: String
    var deviceKey: Data
    var hostID: String
    var hostName: String
}

func statePath(_ directory: String) -> String {
    directory + "/device.json"
}

func loadDevice() -> LabDevice {
    let path = statePath(option("state"))
    guard let data = FileManager.default.contents(atPath: path),
          let device = try? JSONDecoder().decode(LabDevice.self, from: data)
    else { fail("no paired device in \(path); run pair first") }
    return device
}

// MARK: - A link

func message(_ operation: iGhostVTOperation) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
    return message
}

func setData(_ data: Data, _ key: String, in dictionary: xpc_object_t) {
    data.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress {
            xpc_dictionary_set_data(dictionary, key, base, buffer.count)
        }
    }
}

func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
    var count = 0
    guard let bytes = xpc_dictionary_get_data(dictionary, key, &count) else { return nil }
    return Data(bytes: bytes, count: count)
}

func code(of reply: xpc_object_t) -> iGhostVTReplyCode? {
    guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
          xpc_dictionary_get_value(reply, iGhostVTWireKey.code) != nil
    else { return nil }
    return iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code))
}

/// One connection to the host, as `RemoteDaemonLink` makes it once a path
/// won: requests with replies, events out, and — through a relay — a ping
/// whenever either direction has been quiet for the app's interval.
final class LabLink: @unchecked Sendable {
    let queue = DispatchQueue(label: "remote-lab.link")
    let frames: RemoteFrameConnection
    private var pending: [UInt64: (xpc_object_t) -> Void] = [:]
    private var nextTag: UInt64 = 1
    var onEvent: ((xpc_object_t) -> Void)?
    var onClosed: ((String) -> Void)?
    private(set) var lastHeard = Date()
    private(set) var lastSent = Date()
    private(set) var isClosed = false
    let isRelayed: Bool

    init(to endpoint: NWEndpoint, hostID: String, key: RemoteTLS.Key, isRelayed: Bool) {
        self.isRelayed = isRelayed
        let parameters = RemoteTLS.parameters(keys: [key], serverName: hostID)
        frames = RemoteFrameConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
    }

    /// Blocks until TLS is up, or fails.
    func open(timeout: TimeInterval = 20) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var isReady = false
        frames.onReady = {
            isReady = true
            ready.signal()
        }
        frames.onFrame = { [weak self] header, object in self?.received(header, object) }
        frames.onClosed = { [weak self] reason in
            guard let self else { return }
            isClosed = true
            ready.signal()
            let waiting = pending
            pending.removeAll()
            for reply in waiting.values {
                reply(xpc_dictionary_create(nil, nil, 0))
            }
            onClosed?(reason)
        }
        queue.async { self.frames.start() }
        _ = ready.wait(timeout: .now() + timeout)
        if isReady {
            queue.async { self.heartbeat() }
        }
        return isReady
    }

    private func received(_ header: IOWire.Header, _ object: xpc_object_t) {
        lastHeard = Date()
        switch header.kind {
        case .reply:
            pending.removeValue(forKey: header.tag)?(object)
        case .event:
            onEvent?(object)
        case .request, .peerGone:
            break
        }
    }

    func send(_ message: xpc_object_t) {
        queue.async {
            self.lastSent = Date()
            self.frames.send(.request, tag: 0, object: message)
        }
    }

    func send(_ message: xpc_object_t, reply: @escaping (xpc_object_t) -> Void) {
        queue.async {
            guard !self.isClosed else {
                reply(xpc_dictionary_create(nil, nil, 0))
                return
            }
            let tag = self.nextTag
            self.nextTag += 1
            self.pending[tag] = reply
            self.lastSent = Date()
            self.frames.send(.request, tag: tag, object: message)
        }
    }

    func request(_ message: xpc_object_t, timeout: TimeInterval = 30) -> xpc_object_t? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: xpc_object_t?
        send(message) { reply in
            answer = reply
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return answer
    }

    /// The app's relayed heartbeat (`RemoteDaemonLink.heartbeat`).
    private func heartbeat() {
        queue.asyncAfter(deadline: .now() + RemoteAccess.linkPingInterval / 3) { [weak self] in
            guard let self, !isClosed else { return }
            let quiet = Date().timeIntervalSince(lastHeard)
            if quiet > RemoteAccess.linkReplyLimit {
                say("link: nothing from the host in \(Int(quiet)) s, giving up as the app would")
                frames.close(reason: "relayed reply limit")
                return
            }
            if quiet > RemoteAccess.linkPingInterval || Date().timeIntervalSince(lastSent) > RemoteAccess.linkPingInterval {
                let ping = message(.ping)
                let tag = nextTag
                nextTag += 1
                pending[tag] = { _ in }
                lastSent = Date()
                frames.send(.request, tag: tag, object: ping)
            }
            heartbeat()
        }
    }

    func close() {
        queue.sync { frames.close(reason: "done") }
    }
}

struct ConnectError: Error {
    var reason: String
}

func connect(_ device: LabDevice) -> LabLink {
    switch tryConnect(device) {
    case let .success(link): return link
    case let .failure(error): fail(error.reason)
    }
}

func tryConnect(_ device: LabDevice, quiet: Bool = false) -> Result<LabLink, ConnectError> {
    let link: LabLink
    if let direct = options["direct"] {
        link = LabLink(
            to: endpoint(direct),
            hostID: device.hostID,
            key: RemoteTLS.Key(identity: Data(device.deviceID.utf8), secret: device.deviceKey),
            isRelayed: false,
        )
        if !quiet { say("connecting direct to \(direct)") }
    } else {
        guard let data = FileManager.default.contents(atPath: option("relay")),
              var relay = try? RelayConfiguration(data: data)
        else { fail("cannot read the relay configuration") }
        if let via = options["via"], let colon = via.lastIndex(of: ":"), let port = UInt16(via[via.index(after: colon)...]) {
            relay.host = String(via[..<colon])
            relay.port = port
        }
        link = LabLink(
            to: relay.endpoint,
            hostID: device.hostID,
            key: RemoteTLS.Key(identity: Data(device.deviceID.utf8), secret: device.deviceKey),
            isRelayed: true,
        )
        if !quiet { say("connecting through the relay at \(relay.endpointDescription)") }
    }
    let opened = Date()
    guard link.open() else { return .failure(ConnectError(reason: "TLS did not come up")) }
    if !quiet { say(String(format: "TLS up in %.2f s", Date().timeIntervalSince(opened))) }
    let hello = message(.hello)
    guard let exporter = RemoteTLS.exporterSecret(of: link.frames.connection) else {
        return .failure(ConnectError(reason: "no exporter secret"))
    }
    xpc_dictionary_set_string(hello, iGhostVTWireKey.deviceID, device.deviceID)
    xpc_dictionary_set_string(hello, iGhostVTWireKey.deviceName, "Remote Lab")
    xpc_dictionary_set_string(hello, iGhostVTWireKey.appVersion, wireVersion)
    setData(
        RemoteDeviceProof.make(key: device.deviceKey, exporterSecret: exporter, deviceID: device.deviceID),
        iGhostVTWireKey.confirmation,
        in: hello,
    )
    guard let reply = link.request(hello), code(of: reply) == .success else {
        link.close()
        return .failure(ConnectError(reason: "hello refused or unanswered"))
    }
    if !quiet { say(String(format: "hello answered in %.2f s", Date().timeIntervalSince(opened))) }
    return .success(link)
}

// MARK: - pair

func pair() {
    let state = option("state")
    let hostID = option("host-id")
    let deviceID = UUID().uuidString
    let link = LabLink(
        to: endpoint(option("address")),
        hostID: hostID,
        key: RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey),
        isRelayed: false,
    )
    guard link.open() else { fail("pairing connection did not come up") }
    guard let exchange = try? PairingExchange(role: .prover, code: option("code")) else { fail("bad code") }
    let start = message(.pairStart)
    xpc_dictionary_set_string(start, iGhostVTWireKey.deviceID, deviceID)
    xpc_dictionary_set_string(start, iGhostVTWireKey.deviceName, options["name"] ?? "Remote Lab")
    xpc_dictionary_set_string(start, iGhostVTWireKey.appVersion, wireVersion)
    setData(try! exchange.makeShare(), iGhostVTWireKey.share, in: start)
    guard let answer = link.request(start), code(of: answer) == .success,
          let share = data(iGhostVTWireKey.share, in: answer),
          let confirmation = data(iGhostVTWireKey.confirmation, in: answer),
          let hostName = xpc_dictionary_get_string(answer, iGhostVTWireKey.hostName).map({ String(cString: $0) }),
          xpc_dictionary_get_string(answer, iGhostVTWireKey.hostID).map({ String(cString: $0) }) == hostID
    else { fail("pairStart refused") }
    guard (try? exchange.receiveShare(share)) != nil,
          let sessionKey = try? exchange.verifyConfirmation(confirmation)
    else { fail("wrong code") }
    let finish = message(.pairFinish)
    setData(try! exchange.makeConfirmation(), iGhostVTWireKey.confirmation, in: finish)
    guard let done = link.request(finish), code(of: done) == .success else { fail("pairFinish refused") }
    link.close()
    let device = LabDevice(
        deviceID: deviceID,
        deviceKey: PairingExchange.deviceKey(sessionKey: sessionKey, hostID: hostID, deviceID: deviceID),
        hostID: hostID,
        hostName: hostName,
    )
    try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
    let path = statePath(state)
    FileManager.default.createFile(atPath: path, contents: try! JSONEncoder().encode(device), attributes: [.posixPermissions: 0o600])
    print(deviceID)
}

// MARK: - sz

final class HashingWriter: ZmodemFileWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    private(set) var name = ""
    private(set) var byteCount: UInt64 = 0
    private(set) var digest: String?
    private(set) var completed: Bool?

    func beginFile(name: String, size: UInt64?) -> Bool {
        lock.withLock {
            self.name = name
            say("receiving \(name), \(size.map { "\($0) bytes" } ?? "size unknown")")
        }
        return true
    }

    func write(_ bytes: [UInt8]) {
        lock.withLock {
            hasher.update(data: bytes)
            byteCount += UInt64(bytes.count)
        }
    }

    func finishFile() {
        lock.withLock {
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func finish(completed: Bool) {
        lock.withLock { self.completed = completed }
    }

    var received: UInt64 {
        lock.withLock { byteCount }
    }
}

/// What `receiveSZ` keeps across the link's queue, the engine's and its own;
/// every field is touched under `lock`, except `lastCount`, the ticker's.
final class SZRun: @unchecked Sendable {
    var sessionID: UInt64 = 0
    var held: [[UInt8]] = []
    var exitCode: Int64?
    var linkLost: String?
    var lastOutput = Date()
    var longestGap: TimeInterval = 0
    var outputBytes = 0
    var engineState: ZmodemTransferInfo?
    var engineFinished = false
    var lastCount: UInt64 = 0
}

func receiveSZ() -> Int32 {
    let device = loadDevice()
    let file = option("file")
    let sz = options["sz"] ?? "/opt/homebrew/bin/sz"
    let timeout = TimeInterval(options["timeout"] ?? "") ?? 900
    guard let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? UInt64 else {
        fail("no file at \(file)")
    }
    let expected = SHA256.hash(data: FileManager.default.contents(atPath: file)!).map { String(format: "%02x", $0) }.joined()

    let link = connect(device)
    let lock = NSLock()
    let run = SZRun()
    let finished = DispatchSemaphore(value: 0)

    @Sendable func write(_ bytes: [UInt8]) {
        let message = message(.write)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, run.sessionID)
        setData(Data(bytes), iGhostVTWireKey.data, in: message)
        link.send(message)
    }

    let writer = HashingWriter()
    let engine = ZmodemEngine(
        sink: { bytes in
            lock.withLock {
                if run.sessionID == 0 {
                    run.held.append(bytes)
                } else {
                    write(bytes)
                }
            }
        },
        passthrough: { bytes in
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                say("terminal: \(text.debugDescription.prefix(200))")
            }
        },
        makeWriter: { writer },
        requestSource: { $0(nil) },
        onState: { info in
            lock.withLock {
                if run.engineState != nil, info == nil || info?.phase != .active {
                    run.engineFinished = true
                    finished.signal()
                }
                run.engineState = info
            }
        },
    )

    link.onEvent = { event in
        let kind = xpc_dictionary_get_uint64(event, iGhostVTWireKey.event)
        if kind == iGhostVTEvent.output.rawValue, let bytes = data(iGhostVTWireKey.data, in: event) {
            lock.withLock {
                let gap = Date().timeIntervalSince(run.lastOutput)
                if run.outputBytes > 0, gap > run.longestGap {
                    run.longestGap = gap
                }
                if run.outputBytes > 0, gap > 3 {
                    say(String(format: "output resumed after a %.1f s gap", gap))
                }
                run.lastOutput = Date()
                run.outputBytes += bytes.count
            }
            engine.ingest(bytes)
        } else if kind == iGhostVTEvent.sessionExit.rawValue {
            lock.withLock { run.exitCode = xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode) }
            say("sz exited with \(xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))")
            finished.signal()
        }
    }
    link.onClosed = { reason in
        lock.withLock { run.linkLost = reason }
        say("link closed: \(reason)")
        finished.signal()
    }

    let open = message(.openSession)
    xpc_dictionary_set_uint64(open, iGhostVTWireKey.columns, 120)
    xpc_dictionary_set_uint64(open, iGhostVTWireKey.rows, 40)
    let argv = xpc_array_create(nil, 0)
    for argument in [sz, file] {
        xpc_array_append_value(argv, xpc_string_create(argument))
    }
    xpc_dictionary_set_value(open, iGhostVTWireKey.command, argv)
    guard let reply = link.request(open), code(of: reply) == .success else { fail("openSession refused") }
    let transferStarted = Date()
    lock.withLock {
        run.sessionID = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
        for bytes in run.held {
            write(bytes)
        }
        run.held.removeAll()
    }
    say("session \(run.sessionID): \(sz) \(file) (\(size) bytes)")

    // Progress once a second until the transfer, the program or the link ends.
    let ticker = DispatchSource.makeTimerSource(queue: .global())
    ticker.schedule(deadline: .now() + 1, repeating: 1)
    ticker.setEventHandler {
        let count = writer.received
        let rate = Double(count - run.lastCount) / 1024
        run.lastCount = count
        let percent = size > 0 ? Double(count) * 100 / Double(size) : 0
        say(String(format: "%6.1f%%  %llu B  %7.1f KiB/s  host heard %.1f s ago", percent, count, rate, Date().timeIntervalSince(link.lastHeard)))
    }
    ticker.activate()

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        _ = finished.wait(timeout: .now() + 1)
        let done = lock.withLock { run.engineFinished || run.linkLost != nil || (run.exitCode != nil && run.engineState == nil) }
        if done {
            break
        }
    }
    ticker.cancel()
    // Let sz's exit, and the engine's last word, arrive.
    Thread.sleep(forTimeInterval: 1.5)
    let elapsed = Date().timeIntervalSince(transferStarted)

    let (lost, exit, gap) = lock.withLock { (run.linkLost, run.exitCode, run.longestGap) }
    let good = writer.completed == true && writer.digest == expected && writer.received == size
    print("")
    print("RESULT \(good ? "ok" : "FAILED")")
    print(String(format: "  received     %llu of %llu bytes in %.1f s (%.1f KiB/s)", writer.received, size, elapsed, Double(writer.received) / 1024 / max(elapsed, 0.001)))
    print("  checksum     \(writer.digest == expected ? "matches" : (writer.digest == nil ? "none" : "MISMATCH"))")
    print("  engine       \(writer.completed.map { $0 ? "completed" : "cancelled" } ?? "never finished")")
    print("  sz exit      \(exit.map { "\($0)" } ?? "still running")")
    print("  link         \(lost.map { "lost: \($0)" } ?? "up")")
    print(String(format: "  longest gap  %.1f s between output events", gap))
    if lost == nil {
        if exit == nil {
            let kill = message(.closeSession)
            xpc_dictionary_set_uint64(kill, iGhostVTWireKey.sessionID, run.sessionID)
            _ = link.request(kill, timeout: 10)
        }
        link.close()
    }
    return good ? 0 : 2
}

switch command {
case "pair":
    pair()
case "sz":
    exit(receiveSZ())
case "scenario":
    exit(runScenario(option("name")))
default:
    fail("usage: remote-lab pair|sz|scenario …")
}
