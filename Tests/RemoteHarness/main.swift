import CryptoKit
import Dispatch
import Foundation
import Network
import XPC

// The remote-access building blocks, on loopback and an ephemeral port —
// never RemoteAccess.port, and never the user's own daemon: the system's
// SPAKE2+ with the right and a wrong code, the device key both ends derive,
// a real TLS 1.2 ECDHE-PSK handshake through Network.framework, the
// exporter secret both ends read, the device proof, and frames both ways.

var failures = 0

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        failures += 1
        print("  FAIL \(description)")
    }
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

print("pairing exchange")
func pair(proverCode: String, verifierCode: String) -> (prover: SymmetricKey?, verifier: SymmetricKey?) {
    do {
        let prover = try PairingExchange(role: .prover, code: proverCode)
        let verifier = try PairingExchange(role: .verifier, code: verifierCode)
        let x = try prover.makeShare()
        try verifier.receiveShare(x)
        let y = try verifier.makeShare()
        let verifierConfirmation = try verifier.makeConfirmation()
        try prover.receiveShare(y)
        let proverKey = try? prover.verifyConfirmation(verifierConfirmation)
        guard let proverKey else { return (nil, nil) }
        let proverConfirmation = try prover.makeConfirmation()
        let verifierKey = try? verifier.verifyConfirmation(proverConfirmation)
        return (proverKey, verifierKey)
    } catch {
        print("  exchange threw \(error)")
        return (nil, nil)
    }
}

let matched = pair(proverCode: "482913", verifierCode: "482913")
check(matched.prover != nil && matched.verifier != nil, "the same code pairs")
check(matched.prover == matched.verifier, "and both ends hold the same session key")
let mismatched = pair(proverCode: "482914", verifierCode: "482913")
check(mismatched.prover == nil, "a wrong code fails at the prover's check of the host's confirmation")
if let key = matched.prover {
    let a = PairingExchange.deviceKey(sessionKey: key, hostID: "H", deviceID: "D")
    let b = PairingExchange.deviceKey(sessionKey: key, hostID: "H", deviceID: "E")
    check(a.count == 32 && a != b, "the device key is 32 bytes and bound to the device id")
}

let codes = (0 ..< 200).map { _ in RemoteAccess.makePairingCode() }
check(codes.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isNumber) }, "pairing codes are six digits")

print("tls and frames")
let queue = DispatchQueue(label: "remote-harness")
let deviceKey = Data(SHA256.hash(data: Data("device".utf8)))
let deviceID = "DEVICE-1"
let serverKeys = [
    RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey),
    RemoteTLS.Key(identity: Data(deviceID.utf8), secret: deviceKey),
]
let listener = try! NWListener(using: RemoteTLS.parameters(keys: serverKeys), on: .any)
var serverSide: RemoteFrameConnection?
var serverExporter: Data?
var serverReceived: [xpc_object_t] = []
var negotiatedSuite: UInt16 = 0
listener.newConnectionHandler = { connection in
    let frames = RemoteFrameConnection(connection: connection, queue: queue)
    frames.onReady = {
        serverExporter = RemoteTLS.exporterSecret(of: connection)
        if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            negotiatedSuite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
        }
    }
    frames.onFrame = { header, object in
        serverReceived.append(object)
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(reply, "echo", "pong")
        frames.send(.reply, tag: header.tag, object: reply)
    }
    serverSide = frames
    frames.start()
}

var listenerReady = false
listener.stateUpdateHandler = { state in
    if case .ready = state {
        listenerReady = true
    }
}

listener.start(queue: queue)
check(waitUntil { queue.sync { listenerReady } }, "a loopback listener comes up")
let port = listener.port!

func connect(_ key: RemoteTLS.Key) -> (RemoteFrameConnection, () -> Bool, () -> [xpc_object_t], () -> String?) {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: RemoteTLS.parameters(keys: [key]))
    let frames = RemoteFrameConnection(connection: connection, queue: queue)
    var ready = false
    var replies: [xpc_object_t] = []
    var closed: String?
    frames.onReady = { ready = true }
    frames.onFrame = { _, object in replies.append(object) }
    frames.onClosed = { closed = $0 }
    frames.start()
    return (frames, { queue.sync { ready } }, { queue.sync { replies } }, { queue.sync { closed } })
}

let device = connect(RemoteTLS.Key(identity: Data(deviceID.utf8), secret: deviceKey))
check(waitUntil { device.1() }, "a device key completes the TLS handshake")
check(queue.sync { negotiatedSuite } == RemoteTLS.cipherSuite, "with ECDHE-PSK-CHACHA20-POLY1305 (0x\(String(queue.sync { negotiatedSuite }, radix: 16)))")
let clientExporter = queue.sync { RemoteTLS.exporterSecret(of: device.0.connection) }
check(clientExporter != nil && clientExporter == queue.sync { serverExporter }, "both ends read the same exporter secret")
if let clientExporter {
    let proof = RemoteDeviceProof.make(key: deviceKey, exporterSecret: clientExporter, deviceID: deviceID)
    check(
        RemoteDeviceProof.verify(proof, key: deviceKey, exporterSecret: clientExporter, deviceID: deviceID),
        "the device proof verifies",
    )
    check(
        !RemoteDeviceProof.verify(proof, key: deviceKey, exporterSecret: clientExporter, deviceID: "OTHER"),
        "and not for another device id",
    )
    check(
        !RemoteDeviceProof.verify(proof, key: deviceKey, exporterSecret: Data(count: 32), deviceID: deviceID),
        "nor for another session",
    )
}

let big = xpc_dictionary_create(nil, nil, 0)
let payload = [UInt8](repeating: 0x41, count: 600_000)
xpc_dictionary_set_data(big, "data", payload, payload.count)
queue.sync { _ = device.0.send(.request, tag: 7, object: big) }
check(waitUntil { device.2().count == 1 }, "a 600 KB frame goes over and its reply comes back")
check(queue.sync { serverReceived.count == 1 && xpc_dictionary_get_count(serverReceived[0]) == 1 }, "the frame arrives whole")

// The link window's arithmetic: both ends count the same frame stream, and
// a receipt reports exactly what arrived — once per receipt interval.
if let server = queue.sync(execute: { serverSide }) {
    let flood = xpc_dictionary_create(nil, nil, 0)
    let floodBytes = [UInt8](repeating: 0x42, count: 600_000)
    xpc_dictionary_set_data(flood, "data", floodBytes, floodBytes.count)
    queue.sync { _ = server.send(.event, tag: 0, object: flood) }
    let sent = queue.sync { server.sentByteCount }
    check(
        waitUntil { queue.sync { device.0.receivedByteCount == sent } },
        "what the host sent (\(sent) B) is what the device counts received",
    )
    let framesBefore = queue.sync { serverReceived.count }
    queue.sync { device.0.acknowledgeReceived() }
    check(waitUntil { queue.sync { serverReceived.count == framesBefore + 1 } }, "past the receipt interval the device sends a receipt")
    let receipt = queue.sync { serverReceived.last! }
    check(
        xpc_dictionary_get_uint64(receipt, iGhostVTWireKey.operation) == iGhostVTOperation.ping.rawValue
            && xpc_dictionary_get_uint64(receipt, iGhostVTWireKey.received) == sent,
        "a ping naming every byte received",
    )
    check(
        waitUntil { queue.sync { server.receivedByteCount == device.0.sentByteCount } },
        "and the counts agree the other way too",
    )
    queue.sync { device.0.acknowledgeReceived() }
    Thread.sleep(forTimeInterval: 0.3)
    check(queue.sync { serverReceived.count } == framesBefore + 1, "with nothing new arrived, no second receipt")
}

let stranger = connect(RemoteTLS.Key(identity: Data("nobody".utf8), secret: Data(count: 32)))
check(waitUntil { stranger.3() != nil }, "an unknown key does not complete the handshake")
check(!stranger.1(), "and never reaches ready")

let pairing = connect(RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey))
check(waitUntil { pairing.1() }, "the public pairing key completes the handshake (the exchange inside is the security)")

check(RemoteFrameConnectionTests.localAddresses(), "only local-network peers count as local")

check(
    RemoteAccess.isCompatible("1.4.0", with: "1.4.1") && RemoteAccess.isCompatible("1.4.3", with: "1.4.0"),
    "patch releases of one line talk to each other",
)
check(
    !RemoteAccess.isCompatible("1.5.0", with: "1.4.1") && !RemoteAccess.isCompatible("2.4.0", with: "1.4.0"),
    "another minor or major does not",
)
check(
    !RemoteAccess.isCompatible("", with: "1.4.1") && !RemoteAccess.isCompatible(nil, with: "1.4.1"),
    "nor a device too old to say its version",
)
check(
    RemoteAccess.isCompatible("1.3.0", with: RemoteAccess.unknownVersion) && RemoteAccess.isCompatible(RemoteAccess.unknownVersion, with: "1.4.1"),
    "a side that does not know its own version is not checked",
)
check(
    RemoteAccess.wireSpelling(of: "1.4.1") == "1.4.0" && RemoteAccess.wireSpelling(of: RemoteAccess.unknownVersion) == RemoteAccess.unknownVersion,
    "a patch release tells other devices its line with patch 0, which 1.4.0's whole-string check accepts",
)
check(RemoteAccess.lineDescription("1.4.1") == "1.4", "a mismatch names the release line")

print(failures == 0 ? "remote harness passed" : "remote harness: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

enum RemoteFrameConnectionTests {
    static func localAddresses() -> Bool {
        func endpoint(_ host: String) -> NWEndpoint {
            .hostPort(host: NWEndpoint.Host(host), port: 1)
        }
        let local = ["10.0.0.2", "192.168.1.5", "172.20.0.1", "169.254.3.3", "127.0.0.1", "fe80::1", "fd00::5", "::1"]
        let remote = ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1"]
        return local.allSatisfy { RemoteNetwork.isLocal(endpoint($0)) }
            && !remote.contains { RemoteNetwork.isLocal(endpoint($0)) }
    }
}
