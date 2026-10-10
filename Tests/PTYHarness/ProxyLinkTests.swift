import Darwin
import Dispatch
import Foundation
import XPC

// The proxy path: IOSupervisor in this process, the real `ighostvtd-io`
// binary as its child, talking over the real socket. Everything ighostvtd
// does on the device except listen on the mach service and authenticate —
// so a request forwarded, a reply matched, output routed to the right
// peer, a peer's departure detaching it, the flow control that keeps the
// proxy small, a crashed child replaced, and the shutdown exit followed.

/// A client as the supervisor sees it. Output is acknowledged as sent
/// immediately, unless the test wants a client that never reads.
final class HarnessPeer: IOPeer {
    let peerID: UInt64
    var acknowledgesOutput = true
    /// Takes output at this many bytes a second rather than at once: a
    /// peer behind a slow network, congested and draining all the while.
    var drainBytesPerSecond: Double?
    private var nextDrain = DispatchTime.now()
    weak var supervisor: IOSupervisor?
    private let lock = NSLock()
    private var events: [xpc_object_t] = []
    private(set) var cutReason: String?
    private var suspendDepth = 0
    private var suspendCount = 0

    init(peerID: UInt64) {
        self.peerID = peerID
    }

    func suspend() {
        lock.lock()
        suspendDepth += 1
        suspendCount += 1
        lock.unlock()
    }

    func resume() {
        lock.lock()
        suspendDepth -= 1
        lock.unlock()
    }

    /// How many times the supervisor held this peer back, and whether every
    /// suspend has since been balanced — libxpc would abort on one that was
    /// not.
    var timesSuspended: Int {
        lock.lock()
        defer { lock.unlock() }
        return suspendCount
    }

    var isBalanced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspendDepth == 0
    }

    func deliver(event: xpc_object_t) {
        lock.lock()
        events.append(event)
        lock.unlock()
        guard xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue else {
            return
        }
        var length = 0
        guard xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length) != nil, length > 0 else { return }
        supervisor?.willSend(length, to: peerID)
        if let rate = drainBytesPerSecond {
            let start = max(nextDrain, DispatchTime.now())
            nextDrain = start + .nanoseconds(Int(Double(length) / rate * 1_000_000_000))
            harnessQueue.asyncAfter(deadline: nextDrain) { [weak self] in
                guard let self else { return }
                supervisor?.didSend(length, to: peerID)
            }
        } else if acknowledgesOutput {
            supervisor?.didSend(length, to: peerID)
        }
    }

    func cutConnection(reason: String) {
        lock.lock()
        cutReason = reason
        lock.unlock()
        supervisor?.peerGone(peerID)
    }

    var wasCut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cutReason != nil
    }

    /// Everything output so far for `sessionID`, as text.
    func output(of sessionID: UInt64) -> String {
        lock.lock()
        defer { lock.unlock() }
        var collected = Data()
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue
            && xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID) == sessionID
        {
            var length = 0
            if let bytes = xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length) {
                collected.append(bytes.assumingMemoryBound(to: UInt8.self), count: length)
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    func outputByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var total = 0
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.output.rawValue
        {
            var length = 0
            _ = xpc_dictionary_get_data(event, iGhostVTWireKey.data, &length)
            total += length
        }
        return total
    }

    /// The events of `kind` for `sessionID` so far, with the holder each
    /// named ("" for none).
    func holders(of kind: iGhostVTEvent, sessionID: UInt64) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
            .filter {
                xpc_dictionary_get_uint64($0, iGhostVTWireKey.event) == kind.rawValue
                    && xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) == sessionID
            }
            .map { xpc_dictionary_get_string($0, iGhostVTWireKey.holder).map { String(cString: $0) } ?? "" }
    }

    func exitCode(of sessionID: UInt64) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        for event in events
            where xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) == iGhostVTEvent.sessionExit.rawValue
            && xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID) == sessionID
        {
            return Int32(truncatingIfNeeded: xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))
        }
        return nil
    }
}

func makeRequest(_ operation: iGhostVTOperation, _ fill: (xpc_object_t) -> Void = { _ in }) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
    xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
    fill(message)
    return message
}

/// Forwards a request the way PeerRelay does and waits for its reply.
func request(
    _ supervisor: IOSupervisor,
    from peer: HarnessPeer,
    _ operation: iGhostVTOperation,
    timeout: TimeInterval = 5,
    _ fill: (xpc_object_t) -> Void = { _ in },
) -> xpc_object_t? {
    let message = makeRequest(operation, fill)
    let done = DispatchSemaphore(value: 0)
    var reply: xpc_object_t?
    harnessQueue.async {
        supervisor.forward(from: peer, message: message, wantsReply: true) { result in
            reply = result
            done.signal()
        }
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return reply
}

func replyCode(_ reply: xpc_object_t?) -> iGhostVTReplyCode? {
    reply.flatMap { iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64($0, iGhostVTWireKey.code)) }
}

/// The `listSessions` row for `sessionID` as `peer` sees it right now.
func listedRow(_ supervisor: IOSupervisor, from peer: HarnessPeer, sessionID: UInt64) -> xpc_object_t? {
    guard let listed = request(supervisor, from: peer, .listSessions),
          let sessions = xpc_dictionary_get_value(listed, iGhostVTWireKey.sessions)
    else { return nil }
    for index in 0 ..< xpc_array_get_count(sessions) {
        let row = xpc_array_get_value(sessions, index)
        if xpc_dictionary_get_uint64(row, iGhostVTWireKey.sessionID) == sessionID {
            return row
        }
    }
    return nil
}

/// A string field of a `listSessions` row. `xpc_dictionary_get_string`
/// hands back a pointer the dictionary owns, so the conversion happens
/// while the reply is still alive — reading it afterwards yields whatever
/// the freed allocation now holds.
func listedString(
    _ supervisor: IOSupervisor,
    from peer: HarnessPeer,
    sessionID: UInt64,
    _ key: String,
) -> String? {
    guard let row = listedRow(supervisor, from: peer, sessionID: sessionID) else { return nil }
    return withExtendedLifetime(row) {
        xpc_dictionary_get_string(row, key).map { String(cString: $0) }
    }
}

/// The `attributes` dictionary of a reply or row, read while it is alive.
/// `nil` when the key is missing — a daemon that keeps none.
func attributes(in message: xpc_object_t?) -> [String: String]? {
    guard let message,
          let dictionary = xpc_dictionary_get_value(message, iGhostVTWireKey.attributes),
          xpc_get_type(dictionary) == iGhostVTXPC.typeDictionary
    else { return nil }
    var values: [String: String] = [:]
    xpc_dictionary_apply(dictionary) { key, value in
        if let string = xpc_string_get_string_ptr(value) {
            values[String(cString: key)] = String(cString: string)
        }
        return true
    }
    return values
}

/// A `setSessionAttributes` request from `peer`, answered.
func setAttributes(
    _ supervisor: IOSupervisor,
    from peer: HarnessPeer,
    sessionID: UInt64,
    _ values: [String: String]?,
) -> iGhostVTReplyCode? {
    replyCode(request(supervisor, from: peer, .setSessionAttributes) { message in
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
        guard let values else { return }
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        for (key, value) in values {
            xpc_dictionary_set_string(dictionary, key, value)
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, dictionary)
    })
}

func setInput(_ message: xpc_object_t, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
}

func dataText(_ reply: xpc_object_t?) -> String {
    var length = 0
    guard let bytes = reply.flatMap({ xpc_dictionary_get_data($0, iGhostVTWireKey.data, &length) }) else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(50000)
    }
    return condition()
}

/// A writer whose reader keeps up only most of the time: the backlog rises
/// and falls but never empties, which is what the flow control produces
/// under a steady flood. The accumulator must not keep what was written.
func runChannelBacklogTest() {
    print("channel backlog that never fully drains")
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        check(false, "a socket pair for the channel")
        return
    }
    let channel = IOChannel(descriptor: pair[0], queue: harnessQueue)
    harnessQueue.sync { channel.activate() }
    let reader = pair[1]
    _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL, 0) | O_NONBLOCK)
    let frame = xpc_dictionary_create(nil, nil, 0)
    let payload = [UInt8](repeating: 0x78, count: 60 * 1024)
    payload.withUnsafeBytes { xpc_dictionary_set_data(frame, "d", $0.baseAddress!, $0.count) }
    var live = 0
    channel.onPendingChange = { live = $0 }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var sent = 0
    var largest = 0
    let total = 256 << 20
    while sent < total {
        // Up to a megabyte queued, then read until half a megabyte is: the
        // backlog never reaches zero, so a reset-on-empty never happens.
        let storage = harnessQueue.sync { () -> Int in
            while live < 1 << 20 {
                channel.send(.event, peer: 1, tag: 0, object: frame)
                sent += payload.count
            }
            return channel.outboundStorageByteCount
        }
        largest = max(largest, storage)
        while harnessQueue.sync(execute: { live }) > 512 * 1024 {
            if read(reader, &buffer, buffer.count) <= 0 {
                usleep(1000)
            }
        }
    }
    check(
        largest < 8 << 20,
        "a backlog that never empties stays bounded (\(largest >> 10) KiB at most after \(total >> 20) MiB)",
    )
    harnessQueue.sync { channel.close() }
    close(reader)
}

/// A peer the proxy dropped while output for it was queued: what had not
/// begun to leave is thrown away, everything else arrives whole and in
/// order — the frame half written when the peer went included.
func runChannelDiscardTest() {
    print("channel discards a gone peer's queued frames")
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        check(false, "a socket pair for the channel")
        return
    }
    let channel = IOChannel(descriptor: pair[0], queue: harnessQueue)
    harnessQueue.sync { channel.activate() }
    let reader = pair[1]
    var live = 0
    channel.onPendingChange = { live = $0 }
    func frame(_ index: Int) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, "n", UInt64(index))
        let payload = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 48 * 1024)
        payload.withUnsafeBytes { xpc_dictionary_set_data(message, "d", $0.baseAddress!, $0.count) }
        return message
    }
    // Peers 1 and 2 interleaved, far more than the socket holds, so most
    // of it is queued and one frame is cut where the socket filled.
    let (freed, pendingBefore, pendingAfter) = harnessQueue.sync { () -> (Int, Int, Int) in
        for index in 0 ..< 200 {
            channel.send(.event, peer: index % 2 == 0 ? 1 : 2, tag: UInt64(index), object: frame(index))
        }
        let before = live
        let freed = channel.discardQueuedFrames(forPeer: 2)
        return (freed, before, live)
    }
    check(freed > 0 && pendingAfter == pendingBefore - freed, "the gone peer's queued bytes are freed (\(freed >> 10) KiB)")
    // Read everything back and decode it frame by frame.
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL, 0) | O_NONBLOCK)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let count = read(reader, &buffer, buffer.count)
        if count > 0 {
            received.append(contentsOf: buffer[0 ..< count])
        } else if harnessQueue.sync(execute: { live }) == 0 {
            // The channel may have flushed its last bytes between that
            // read and this check: take what the socket still holds.
            while case let count = read(reader, &buffer, buffer.count), count > 0 {
                received.append(contentsOf: buffer[0 ..< count])
            }
            break
        } else {
            usleep(1000)
        }
    }
    var tags: [UInt64] = []
    var whole = true
    received.withUnsafeBytes { bytes in
        var cursor = 0
        while cursor < bytes.count {
            let rest = UnsafeRawBufferPointer(rebasing: bytes[cursor...])
            guard let header = IOWire.decodeHeader(rest),
                  rest.count >= IOWire.headerByteCount + header.payloadByteCount,
                  let message = IOCodec.decode(UnsafeRawBufferPointer(
                      rebasing: rest[IOWire.headerByteCount ..< IOWire.headerByteCount + header.payloadByteCount],
                  )),
                  xpc_dictionary_get_uint64(message, "n") == header.tag
            else {
                whole = false
                return
            }
            tags.append(header.tag)
            cursor += IOWire.headerByteCount + header.payloadByteCount
        }
    }
    check(whole, "every frame that arrives is whole (\(tags.count) frames)")
    check(tags == tags.sorted(), "and in the order it was sent")
    check(tags.filter { $0 % 2 == 0 }.count == 100, "the other peer loses nothing")
    let gone = tags.filter { $0 % 2 == 1 }
    // Only what had begun to leave when the peer went: here at most the
    // frame the socket cut, since the buffer is smaller than a frame.
    check(gone.count <= 1, "the gone peer's queued frames are not sent (\(gone.count) of 100 had begun)")
    harnessQueue.sync { channel.close() }
    close(reader)
}

func runCodecTests() {
    print("wire codec")
    let original = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(original, "u", UInt64.max)
    xpc_dictionary_set_int64(original, "i", -42)
    xpc_dictionary_set_bool(original, "b", true)
    xpc_dictionary_set_string(original, "s", "héllo wörld")
    let bytes: [UInt8] = [0, 1, 2, 255, 0]
    bytes.withUnsafeBytes { xpc_dictionary_set_data(original, "d", $0.baseAddress!, $0.count) }
    let array = xpc_array_create(nil, 0)
    xpc_array_append_value(array, xpc_string_create("one"))
    let nested = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(nested, "n", 7)
    xpc_array_append_value(array, nested)
    xpc_dictionary_set_value(original, "a", array)
    let environment = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(environment, "TERM", "xterm-ghostty")
    xpc_dictionary_set_value(original, "env", environment)

    var encoded: [UInt8] = []
    check(IOCodec.encode(original, into: &encoded), "a protocol dictionary encodes")
    let decoded = encoded.withUnsafeBytes { IOCodec.decode($0) }
    check(decoded != nil, "the encoding decodes")
    if let decoded {
        check(xpc_dictionary_get_uint64(decoded, "u") == UInt64.max, "uint64 survives")
        check(xpc_dictionary_get_int64(decoded, "i") == -42, "int64 survives")
        check(xpc_dictionary_get_bool(decoded, "b"), "bool survives")
        check(
            xpc_dictionary_get_string(decoded, "s").map { String(cString: $0) } == "héllo wörld",
            "a non-ASCII string survives",
        )
        var length = 0
        let data = xpc_dictionary_get_data(decoded, "d", &length)
        check(
            length == 5 && data.map { Array(UnsafeRawBufferPointer(start: $0, count: 5)) } == bytes,
            "data with embedded NULs survives",
        )
        let decodedArray = xpc_dictionary_get_value(decoded, "a")
        check(
            decodedArray.map { xpc_array_get_count($0) } == 2
                && decodedArray.flatMap { xpc_array_get_string($0, 0) }.map { String(cString: $0) } == "one"
                && decodedArray
                .map { xpc_uint64_get_value(xpc_dictionary_get_value(xpc_array_get_value($0, 1), "n")!) } == 7,
            "an array of mixed values survives",
        )
        check(
            xpc_dictionary_get_value(decoded, "env").flatMap { xpc_dictionary_get_string($0, "TERM") }
                .map { String(cString: $0) } == "xterm-ghostty",
            "a nested dictionary survives",
        )
        check(xpc_dictionary_get_count(decoded) == 7, "no keys are invented or lost")
    }

    let truncated = Array(encoded.dropLast(3))
    check(truncated.withUnsafeBytes { IOCodec.decode($0) } == nil, "a truncated payload is refused")
    var overlong = encoded
    overlong.append(0)
    check(overlong.withUnsafeBytes { IOCodec.decode($0) } == nil, "trailing bytes are refused")

    let unsupported = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_fd(unsupported, "fd", STDIN_FILENO)
    var scratch: [UInt8] = []
    check(!IOCodec.encode(unsupported, into: &scratch), "a descriptor is not carried")

    var framed: [UInt8] = []
    IOWire.appendHeader(IOWire.Header(kind: .reply, peer: 9, tag: 12345, payloadByteCount: encoded.count), to: &framed)
    let header = framed.withUnsafeBytes { IOWire.decodeHeader($0) }
    check(
        header?.kind == .reply && header?.peer == 9 && header?.tag == 12345
            && header?.payloadByteCount == encoded.count,
        "a frame header round-trips",
    )
    framed[4] = 200
    check(framed.withUnsafeBytes { IOWire.decodeHeader($0) } == nil, "an unknown frame kind is refused")
}

func runProxyLinkTests() {
    runCodecTests()
    runChannelBacklogTest()
    runChannelDiscardTest()

    print("proxy link")
    guard let ioBinary = ProcessInfo.processInfo.environment["IGHOSTVT_IO_BINARY"] else {
        check(false, "IGHOSTVT_IO_BINARY names the io binary")
        return
    }
    IOSupervisor.peerCongestionGrace = .seconds(2)
    // The idle exit has its own test below; nothing else here may race it.
    IOSupervisor.idleExitDelay = .seconds(3600)
    let supervisor = IOSupervisor(queue: harnessQueue, executablePath: ioBinary)
    var shutdownFollowed = false
    supervisor.onShutdownExit = { shutdownFollowed = true }
    var spawned = false
    harnessQueue.sync {
        do {
            try supervisor.start()
            spawned = true
        } catch {
            spawned = false
        }
    }
    check(spawned, "the supervisor spawns ighostvtd-io")
    guard spawned else { return }
    let firstChild = supervisor.childProcessID
    check(firstChild > 0, "the child has a pid")
    check(kill(firstChild, 0) == 0, "the child is running")

    let peer = HarnessPeer(peerID: 1)
    peer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(peer) }

    check(
        replyCode(request(supervisor, from: peer, .openSession)) == .handshakeRequired,
        "a request before hello is refused by io, through the proxy",
    )
    check(replyCode(request(supervisor, from: peer, .hello)) == .success, "hello is forwarded and answered")

    let listedShells = request(supervisor, from: peer, .listShells)
        .flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.shells) }
    let shellPaths = listedShells.map { array in
        (0 ..< xpc_array_get_count(array)).compactMap {
            xpc_array_get_string(array, $0).map { String(cString: $0) }
        }
    }
    check(shellPaths?.contains("/bin/sh") == true, "the daemon lists executable common shells")

    // The Mac's own update: a harness build is not in /Applications, so it
    // says it cannot update itself — and asking with no key starts nothing.
    // The state is read while the reply is still held: the string's
    // pointer belongs to the dictionary.
    func updateState(_ fill: (xpc_object_t) -> Void = { _ in }) -> String? {
        guard let reply = request(supervisor, from: peer, .hostUpdate, fill) else { return nil }
        return withExtendedLifetime(reply) {
            xpc_dictionary_get_string(reply, iGhostVTWireKey.updateState).map { String(cString: $0) }
        }
    }
    check(updateState() == HostUpdateState.idle.rawValue, "hostUpdate with no key starts nothing (idle)")
    _ = updateState { xpc_dictionary_set_bool($0, iGhostVTWireKey.updateCheck, true) }
    check(
        waitUntil(10) { updateState() == HostUpdateState.unsupported.rawValue },
        "a copy outside /Applications says it does not update itself",
    )

    let opened = request(supervisor, from: peer, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "echo hello-from-io; exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, 80)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, 24)
    }
    check(replyCode(opened) == .success, "a session opens through the proxy (\(String(describing: opened)))")
    let sessionID = opened.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(sessionID > 0, "the reply names the session")
    check(attributes(in: opened) == [:], "the open reply states the session's attributes, none yet")
    check(
        opened.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.processName) }
            .map { String(cString: $0) } == "sh",
        "the reply states the foreground process",
    )
    check(
        waitUntil { peer.output(of: sessionID).contains("hello-from-io") },
        "output reaches the peer that opened the session",
    )

    // A write the app sends without expecting a reply: no tag, no reply.
    harnessQueue.async {
        let message = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            let bytes = Array("ping-through-proxy\n".utf8)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
        }
        supervisor.forward(from: peer, message: message, wantsReply: false) { _ in
            check(false, "a request without a reply never completes")
        }
    }
    check(
        waitUntil { peer.output(of: sessionID).contains("ping-through-proxy") },
        "input written through the proxy comes back out",
    )

    // A paste: more than one chunk, sent back to back without waiting for
    // anything, the way the app sends one. It has to come out the far end
    // whole and in order — the proxy forwards frames as it reads them, and
    // the session queues them in that order — and none of it may be lost to
    // a PTY master that only takes about a kilobyte at a time.
    //
    // Its own session, in raw mode: a canonical-mode terminal has a line
    // length of its own and would hold a chunk with no newline in it, which
    // is the kernel's business and not this test's.
    print("proxy chunked paste")
    let pasteOpened = request(supervisor, from: peer, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "stty raw -echo; exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let pasteID = pasteOpened.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(pasteOpened) == .success && pasteID > 0, "a session for the paste opens")
    // Let `stty` run before anything is typed at it.
    Thread.sleep(forTimeInterval: 0.5)
    let pasteChunk = String(repeating: "0123456789abcdef", count: 1024) // 16 KiB
    let pasteChunkCount = 3
    harnessQueue.async {
        for index in 0 ..< pasteChunkCount {
            let message = makeRequest(.write) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, pasteID)
                setInput(message, "<\(index)>" + pasteChunk)
            }
            supervisor.forward(from: peer, message: message, wantsReply: false) { _ in }
        }
        let terminator = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, pasteID)
            setInput(message, "paste-end")
        }
        supervisor.forward(from: peer, message: terminator, wantsReply: false) { _ in }
    }
    check(
        waitUntil(20) { peer.output(of: pasteID).contains("paste-end") },
        "a multi-chunk paste reaches the end of the session's input",
    )
    let pasted = peer.output(of: pasteID)
    let arrived = pasted.components(separatedBy: pasteChunk).count - 1
    check(
        arrived == pasteChunkCount,
        "every chunk of it arrived whole (\(arrived) of \(pasteChunkCount))",
    )
    check(
        pasted.count == pasteChunkCount * (pasteChunk.count + 3) + "paste-end".count,
        "with nothing added or lost around them (\(pasted.count) characters)",
    )
    check(
        (0 ..< pasteChunkCount).allSatisfy { index in
            guard let marker = pasted.range(of: "<\(index)>"),
                  let end = pasted.range(of: "paste-end") else { return false }
            guard index > 0 else { return marker.lowerBound < end.lowerBound }
            guard let previous = pasted.range(of: "<\(index - 1)>") else { return false }
            return previous.lowerBound < marker.lowerBound && marker.lowerBound < end.lowerBound
        },
        "and in the order it was sent",
    )
    check(
        replyCode(request(supervisor, from: peer, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, pasteID)
        }) == .success,
        "the paste session closes",
    )
    _ = waitUntil { listedRow(supervisor, from: peer, sessionID: pasteID) == nil }

    let listed = request(supervisor, from: peer, .listSessions)
    let sessions = listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
    check(sessions.map { xpc_array_get_count($0) } == 1, "listSessions sees the one session")
    check(
        sessions.map { xpc_dictionary_get_bool(xpc_array_get_value($0, 0), iGhostVTWireKey.isAttached) } == true,
        "and reports it attached",
    )

    let second = HarnessPeer(peerID: 2)
    second.supervisor = supervisor
    harnessQueue.sync { supervisor.register(second) }
    check(replyCode(request(supervisor, from: second, .hello)) == .success, "a second peer says hello")
    check(
        replyCode(request(supervisor, from: second, .attachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .sessionBusy,
        "a session attached elsewhere is busy",
    )

    // A device picks up a tab another peer has open: the holder is told,
    // the watchers hear when the device lets go, and the first peer gets
    // it back.
    print("proxy takeover and watchers")
    let watcher = HarnessPeer(peerID: 3)
    watcher.supervisor = supervisor
    harnessQueue.sync { supervisor.register(watcher) }
    check(
        replyCode(request(supervisor, from: watcher, .hello) {
            xpc_dictionary_set_bool($0, iGhostVTWireKey.watchSessions, true)
        }) == .success,
        "a watcher says hello",
    )
    check(
        replyCode(request(supervisor, from: second, .attachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
            xpc_dictionary_set_string($0, iGhostVTWireKey.holder, "Phone")
            xpc_dictionary_set_bool($0, iGhostVTWireKey.takeover, true)
        }) == .success,
        "a takeover attaches a session another peer holds",
    )
    check(
        waitUntil { peer.holders(of: .sessionTaken, sessionID: sessionID) == ["Phone"] },
        "the peer that held it hears who took it",
    )
    check(
        listedString(supervisor, from: watcher, sessionID: sessionID, iGhostVTWireKey.holder) == "Phone",
        "the session is listed as held for that device",
    )
    let busyReply = request(supervisor, from: peer, .attachSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    }
    check(
        replyCode(busyReply) == .sessionBusy
            && busyReply.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.holder) }.map { String(cString: $0) } == "Phone",
        "an attach without takeover is busy and names the holder",
    )
    check(
        replyCode(request(supervisor, from: second, .detachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .success,
        "the device lets go",
    )
    check(
        waitUntil { watcher.holders(of: .sessionReleased, sessionID: sessionID) == ["Phone"] },
        "the watcher hears the session is free",
    )
    check(
        replyCode(request(supervisor, from: peer, .attachSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .success,
        "and the first peer attaches it again",
    )
    let deviceOpened = request(supervisor, from: second, .openSession) {
        xpc_dictionary_set_string($0, iGhostVTWireKey.holder, "Phone")
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.columns, 80)
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.rows, 24)
    }
    let deviceSessionID = deviceOpened.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(deviceOpened) == .success && deviceSessionID > 0, "a session opens for a device")
    check(
        waitUntil { watcher.holders(of: .sessionOpened, sessionID: deviceSessionID) == ["Phone"] },
        "the watcher hears of it",
    )
    check(
        replyCode(request(supervisor, from: second, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, deviceSessionID)
        }) == .success,
        "the device ends it",
    )
    check(
        waitUntil { watcher.exitCode(of: deviceSessionID) != nil },
        "the watcher hears it ended, holding nothing",
    )
    check(
        watcher.holders(of: .sessionReleased, sessionID: deviceSessionID).isEmpty,
        "an ended session is not released",
    )

    // The CLI's requests hold nothing: a snapshot reads the replay and
    // injected input reaches the PTY while the first peer keeps the session.
    print("proxy snapshot and inject")
    // The foreground-name poll runs every 500 ms, so wait for it to settle
    // on `cat` (through the list) before asserting the snapshot names it.
    _ = waitUntil {
        listedRow(supervisor, from: second, sessionID: sessionID).map {
            xpc_dictionary_get_string($0, iGhostVTWireKey.processName).map { String(cString: $0) } == "cat"
        } == true
    }
    let snapshot = request(supervisor, from: second, .snapshotSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    }
    check(replyCode(snapshot) == .success, "a snapshot needs no attachment")
    let snapshotText = dataText(snapshot)
    check(
        snapshotText.contains("hello-from-io") && snapshotText.contains("ping-through-proxy"),
        "the snapshot carries the replay",
    )
    check(
        snapshot.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.columns) } == 80
            && snapshot.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.rows) } == 24,
        "the snapshot states the size",
    )
    check(
        snapshot.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.processName) }
            .map { String(cString: $0) } == "cat",
        "the snapshot states the foreground process",
    )
    check(
        listedRow(supervisor, from: second, sessionID: sessionID)
            .map { xpc_dictionary_get_bool($0, iGhostVTWireKey.isAttached) } == true,
        "the snapshot left the session attached to its peer",
    )
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
            setInput($0, "from-second\n")
        }) == .success,
        "injected input needs no attachment",
    )
    check(waitUntil { peer.output(of: sessionID).contains("from-second") }, "injected input reaches the attached peer")
    check(!second.output(of: sessionID).contains("from-second"), "and nothing comes back to the peer that injected it")
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .invalidRequest,
        "injected input without data is refused",
    )
    check(
        replyCode(request(supervisor, from: second, .snapshotSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, 999)
        }) == .unknownSession,
        "a snapshot of an unknown session is refused",
    )
    check(
        replyCode(request(supervisor, from: second, .injectInput) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, 999)
            setInput($0, "x")
        }) == .unknownSession,
        "input into an unknown session is refused",
    )
    check(
        waitUntil {
            listedRow(supervisor, from: second, sessionID: sessionID).map {
                xpc_dictionary_get_string($0, iGhostVTWireKey.processName).map { String(cString: $0) } == "cat"
                    && xpc_dictionary_get_bool($0, iGhostVTWireKey.foregroundIsShell)
            } == true
        },
        "a listed row names the foreground process",
    )
    let listedDirectory = listedString(
        supervisor,
        from: second,
        sessionID: sessionID,
        iGhostVTWireKey.currentDirectory,
    )
    check(
        listedDirectory?.hasPrefix("/") == true,
        "a listed row states the shell's directory (got \(listedDirectory ?? "nil"))",
    )
    let placed = request(supervisor, from: second, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "cd /private/tmp && exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let placedID = placed.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(placed) == .success && placedID > 0, "a session opens in a chosen directory")
    check(
        waitUntil {
            listedString(supervisor, from: second, sessionID: placedID, iGhostVTWireKey.currentDirectory)
                == "/private/tmp"
        },
        "and its row states that directory as the kernel spells it",
    )
    check(
        replyCode(request(supervisor, from: second, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, placedID)
        }) == .success,
        "the placed session closes",
    )
    check(
        waitUntil { listedRow(supervisor, from: second, sessionID: placedID) == nil },
        "and leaves the list",
    )

    // A one-word `cmd` is the CLI's `new -- /usr/bin/python3`: the program
    // itself, not a login shell of that name. `env` alone prints what it was
    // handed, which also shows the verbatim environment at the far end.
    print("proxy one-word command")
    let oneWord = request(supervisor, from: second, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        xpc_array_append_value(command, xpc_string_create("/usr/bin/env"))
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let oneWordID = oneWord.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(oneWord) == .success && oneWordID > 0, "a one-word command opens")
    check(waitUntil { second.exitCode(of: oneWordID) != nil }, "and runs to its end")
    check(
        second.exitCode(of: oneWordID) == 0,
        "as itself, not as `env -il` (exit \(String(describing: second.exitCode(of: oneWordID))))",
    )
    let printed = second.output(of: oneWordID)
    check(printed.contains("TERM=xterm-256color"), "a verbatim command sees TERM")
    check(printed.contains("TERM_PROGRAM=iGhostVT"), "and the terminal's identity")
    check(printed.contains("PATH=/"), "and a PATH")
    check(printed.contains("HOME=") && printed.contains("LC_CTYPE="), "and HOME and LC_CTYPE")
    check(!printed.contains("GHOSTTY_"), "and no shell integration")

    // The new-tab menu's recent rows: a directory named outright, and the
    // reply stating where the session actually landed — which is what the
    // app records as a visit.
    print("proxy named start directory")
    let started = request(supervisor, from: second, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        xpc_array_append_value(command, xpc_string_create("/bin/sh"))
        xpc_array_append_value(command, xpc_string_create("-c"))
        xpc_array_append_value(command, xpc_string_create("exec /bin/sleep 30"))
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
        xpc_dictionary_set_string(message, iGhostVTWireKey.startDirectory, "/private/tmp")
    }
    let startedID = started.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(started) == .success && startedID > 0, "a session opens on a named directory")
    let reportedDirectory = started.flatMap { reply in
        withExtendedLifetime(reply) {
            xpc_dictionary_get_string(reply, iGhostVTWireKey.currentDirectory)
                .map { String(cString: $0) }
        }
    }
    check(
        reportedDirectory == "/private/tmp",
        "and the reply says where it landed (got \(String(describing: reportedDirectory)))",
    )
    let startedRowDirectory = listedString(
        supervisor,
        from: second,
        sessionID: startedID,
        iGhostVTWireKey.currentDirectory,
    )
    check(
        startedRowDirectory == "/private/tmp",
        "and so does its row in the list (got \(String(describing: startedRowDirectory)))",
    )
    _ = request(supervisor, from: second, .closeSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, startedID)
    }
    _ = waitUntil { listedRow(supervisor, from: second, sessionID: startedID) == nil }

    // A session with no directory of its own starts in the session user's
    // home, and the daemon is the only side that knows which directory
    // that is — under roothide it is inside the jbroot, not `/var/mobile`.
    // It says so by spelling it `~`, which is what keeps the menu from
    // offering the home twice.
    let homed = request(supervisor, from: second, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        xpc_array_append_value(command, xpc_string_create("/bin/sh"))
        xpc_array_append_value(command, xpc_string_create("-c"))
        xpc_array_append_value(command, xpc_string_create("exec /bin/sleep 30"))
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let homedID = homed.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(homed) == .success && homedID > 0, "a session opens with no directory named")
    let homedDisplay = listedString(
        supervisor,
        from: second,
        sessionID: homedID,
        iGhostVTWireKey.displayDirectory,
    )
    check(homedDisplay == "~", "and its home is reported as ~ (got \(String(describing: homedDisplay)))")
    let homedPath = listedString(
        supervisor,
        from: second,
        sessionID: homedID,
        iGhostVTWireKey.currentDirectory,
    )
    check(
        homedPath.map { $0.hasPrefix("/") } == true,
        "while the spelling chdir wants stays a real path (got \(String(describing: homedPath)))",
    )
    _ = request(supervisor, from: second, .closeSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, homedID)
    }
    _ = waitUntil { listedRow(supervisor, from: second, sessionID: homedID) == nil }

    // The app's Settings choice travels under `shell` and is a login shell.
    let chosen = request(supervisor, from: second, .openSession) { message in
        xpc_dictionary_set_string(message, iGhostVTWireKey.shell, "/bin/sh")
    }
    let chosenID = chosen.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(chosen) == .success && chosenID > 0, "a chosen shell opens")
    harnessQueue.async {
        let message = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, chosenID)
            setInput(message, "echo \"shell:$0 flags:$-\"\n")
        }
        supervisor.forward(from: second, message: message, wantsReply: false) { _ in }
    }
    check(
        waitUntil { second.output(of: chosenID).contains("shell:/bin/sh flags:") },
        "the chosen shell answers as itself",
    )
    let flags = second.output(of: chosenID)
        .components(separatedBy: "shell:/bin/sh flags:")
        .dropFirst()
        .first.map { $0.prefix { !$0.isNewline } } ?? ""
    check(flags.contains("i"), "and runs interactively, as a login shell does (flags: \(flags))")
    _ = request(supervisor, from: second, .closeSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, chosenID)
    }
    _ = waitUntil { listedRow(supervisor, from: second, sessionID: chosenID) == nil }

    // What a client keeps on a session: set by any peer, stated on every
    // row and attach, refused whole past the limits, gone with the session.
    print("proxy session attributes")
    let lock = [iGhostVTSessionAttribute.lock: iGhostVTSessionAttribute.keyboardLock]
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, lock) == .success,
        "a peer that does not hold the session sets its attributes",
    )
    check(
        attributes(in: listedRow(supervisor, from: second, sessionID: sessionID)) == lock,
        "and its row states them",
    )
    let snapshotAttributes = attributes(in: request(supervisor, from: second, .snapshotSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    })
    check(snapshotAttributes == lock, "and so does a snapshot (got \(String(describing: snapshotAttributes)))")
    let tooMany = Dictionary(uniqueKeysWithValues: (0 ... iGhostVTProtocol.maximumSessionAttributeCount).map {
        ("k\($0)", "v")
    })
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, tooMany) == .invalidRequest,
        "\(tooMany.count) keys are refused",
    )
    let fullValue = String(repeating: "x", count: iGhostVTProtocol.maximumSessionAttributeByteCount - 1)
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, ["k": fullValue]) == .success,
        "exactly the byte limit is accepted",
    )
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, ["k": fullValue + "x"]) == .invalidRequest,
        "one byte past it is refused",
    )
    check(
        attributes(in: listedRow(supervisor, from: second, sessionID: sessionID)) == ["k": fullValue],
        "and a refused request changed nothing",
    )
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, nil) == .invalidRequest,
        "a request without attributes is refused",
    )
    check(
        replyCode(request(supervisor, from: second, .setSessionAttributes) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(dictionary, iGhostVTSessionAttribute.lock, 1)
            xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, dictionary)
        }) == .invalidRequest,
        "a value that is not a string is refused",
    )
    check(
        setAttributes(supervisor, from: second, sessionID: 999, lock) == .unknownSession,
        "attributes for an unknown session are refused",
    )
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, lock) == .success,
        "a request replaces the attributes whole",
    )
    check(
        attributes(in: listedRow(supervisor, from: second, sessionID: sessionID)) == lock,
        "leaving none of the old keys behind",
    )

    runUploadTests(supervisor, first: peer, second: second)

    // Requests no client sends, over and over: each is refused, none is
    // kept, and neither side grows with them. The harness process is the
    // proxy and io's caller both, so its footprint stands for theirs.
    func attributesRequest(_ fill: @escaping (xpc_object_t) -> Void) -> iGhostVTReplyCode? {
        replyCode(request(supervisor, from: second, .setSessionAttributes) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            fill(message)
        })
    }
    let hugeValue = String(repeating: "x", count: 512 * 1024)
    let malformed: [(String, (xpc_object_t) -> Void)] = [
        ("a half-megabyte value", { message in
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(dictionary, "k", hugeValue)
            xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, dictionary)
        }),
        ("a nested dictionary", { message in
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(dictionary, "k", xpc_dictionary_create(nil, nil, 0))
            xpc_dictionary_set_value(message, iGhostVTWireKey.attributes, dictionary)
        }),
        ("a request whose attributes are not a dictionary", { message in
            xpc_dictionary_set_string(message, iGhostVTWireKey.attributes, "lock=keyboard")
        }),
    ]
    for (name, fill) in malformed {
        check(attributesRequest(fill) == .invalidRequest, "\(name) is refused")
    }
    let footprintBefore = footprintBytes()
    var refusedCount = 0
    for round in 0 ..< 600 {
        if attributesRequest(malformed[round % malformed.count].1) == .invalidRequest {
            refusedCount += 1
        }
    }
    let footprintGrowth = Int64(footprintBytes()) - Int64(footprintBefore)
    check(refusedCount == 600, "600 more malformed requests are all refused (\(refusedCount))")
    check(
        footprintGrowth < 16 << 20,
        "and nothing grows with them (\(footprintGrowth >> 10) KiB)",
    )
    check(
        attributes(in: listedRow(supervisor, from: second, sessionID: sessionID)) == lock,
        "the session keeps the attributes it had",
    )

    // The first peer's connection drops: its sessions are detached, not
    // killed, and its replay is what the next peer gets.
    harnessQueue.sync { supervisor.peerGone(1) }
    let attached = request(supervisor, from: second, .attachSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
    }
    check(replyCode(attached) == .success, "after the peer is gone the session attaches elsewhere")
    var replayLength = 0
    let replay = attached.flatMap { xpc_dictionary_get_data($0, iGhostVTWireKey.data, &replayLength) }
    let replayText = replay.map {
        String(decoding: UnsafeRawBufferPointer(start: $0, count: replayLength), as: UTF8.self)
    } ?? ""
    check(
        replayText.contains("hello-from-io") && replayText.contains("ping-through-proxy"),
        "the attach reply replays the buffer",
    )
    check(attributes(in: attached) == lock, "and states the attributes the session kept")
    harnessQueue.async {
        let message = makeRequest(.write) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
            let bytes = Array("second-peer\n".utf8)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
        }
        supervisor.forward(from: second, message: message, wantsReply: false) { _ in }
    }
    check(
        waitUntil { second.output(of: sessionID).contains("second-peer") },
        "output now goes to the attached peer",
    )
    check(!peer.output(of: sessionID).contains("second-peer"), "and not to the departed one")

    check(
        replyCode(request(supervisor, from: second, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }) == .success,
        "closeSession is forwarded",
    )
    check(waitUntil { second.exitCode(of: sessionID) != nil }, "the exit event reaches the attached peer")
    check(
        waitUntil {
            let listed = request(supervisor, from: second, .listSessions)
            return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
                .map { xpc_array_get_count($0) } == 0
        },
        "the closed session leaves the list",
    )
    check(
        setAttributes(supervisor, from: second, sessionID: sessionID, lock) == .unknownSession,
        "its attributes went with it",
    )

    // Flow control. A client that never reads: the proxy must stop taking
    // output, so what it holds stays bounded, then cut the peer.
    print("proxy flow control")
    let stuck = HarnessPeer(peerID: 3)
    stuck.supervisor = supervisor
    stuck.acknowledgesOutput = false
    harnessQueue.sync { supervisor.register(stuck) }
    check(replyCode(request(supervisor, from: stuck, .hello)) == .success, "a stuck peer says hello")
    // Enough to overrun the in-flight cap several times (so the pause and
    // the peer-cut both fire), then a sentinel, then a sleep that keeps the
    // shell alive so its exit does not race the assertions. Kept small on
    // purpose: the point is that the shell reaches its end once someone
    // reads, not how fast a slow runner can move fifty megabytes.
    let flood = request(supervisor, from: stuck, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "yes | head -c 3000000; echo flood-done; sleep 30"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let floodID = flood.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(flood) == .success && floodID > 0, "a flooding session opens")
    _ = waitUntil(3) { stuck.outputByteCount() >= IOSupervisor.pauseAboveByteCount }
    let delivered = stuck.outputByteCount()
    check(
        delivered >= IOSupervisor.pauseAboveByteCount,
        "output flows until the in-flight cap (\(delivered) bytes)",
    )
    usleep(500_000)
    let afterPause = stuck.outputByteCount()
    check(
        afterPause - delivered < IOSupervisor.pauseAboveByteCount,
        "past the cap the proxy stops taking output (\(afterPause - delivered) more bytes)",
    )
    check(waitUntil(6) { stuck.wasCut }, "a peer that does not drain is cut (\(stuck.cutReason ?? "not cut"))")
    // The cut peer's session lives on, detached, and its shell keeps
    // running into the replay buffer instead of blocking.
    let observer = HarnessPeer(peerID: 4)
    observer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(observer) }
    check(replyCode(request(supervisor, from: observer, .hello)) == .success, "an observer says hello")
    let reattached = request(supervisor, from: observer, .attachSession, timeout: 10) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, floodID)
    }
    check(replyCode(reattached) == .success, "the flooding session survives its peer being cut")
    // The reattach reply's replay covers the tail already produced; the rest
    // arrives live now that a reader is draining. Either way the sentinel at
    // the shell's end reaches the observer, which is the proof the shell was
    // never blocked or killed by its first peer going away.
    let reattachReplay: String = {
        var length = 0
        guard let bytes = reattached.flatMap({ xpc_dictionary_get_data($0, iGhostVTWireKey.data, &length) })
        else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
    }()
    check(
        waitUntil(15) {
            reattachReplay.contains("flood-done") || observer.output(of: floodID).contains("flood-done")
        },
        "the shell ran to completion while nobody was reading",
    )
    check(
        replyCode(request(supervisor, from: observer, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, floodID)
        }) == .success,
        "the flooding session closes",
    )
    _ = waitUntil {
        let listed = request(supervisor, from: observer, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
            .map { xpc_array_get_count($0) } == 0
    }

    // A peer behind a slow link — `ighostvtd-remote` relaying an `sz` — is
    // congested far longer than the grace and drains all the while; it
    // must be paced, never cut. Before the deadline moved with progress,
    // it was cut one grace after it first fell behind.
    print("proxy flow control with a slow peer")
    let slow = HarnessPeer(peerID: 5)
    slow.supervisor = supervisor
    slow.drainBytesPerSecond = 400_000
    harnessQueue.sync { supervisor.register(slow) }
    check(replyCode(request(supervisor, from: slow, .hello)) == .success, "a slow peer says hello")
    let trickle = request(supervisor, from: slow, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "head -c 3000000 /dev/zero | tr '\\0' x; echo; echo slow-done; sleep 30"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let trickleID = trickle.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(trickle) == .success && trickleID > 0, "a session floods the slow peer")
    check(
        waitUntil(20) { slow.output(of: trickleID).contains("slow-done") || slow.wasCut },
        "the slow peer is paced through the whole flood",
    )
    check(!slow.wasCut, "and is never cut while it drains (\(slow.cutReason ?? "not cut"))")
    _ = request(supervisor, from: slow, .closeSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, trickleID)
    }
    harnessQueue.sync { supervisor.peerGone(slow.peerID) }

    // The pause is one decision for the socket, the timer was one per peer:
    // three peers each holding less than the per-peer threshold, together
    // past the pause, once left the socket shut with no timer running and
    // every session — and the CLI — stalled behind it.
    print("proxy flow control with several peers")
    let share = 400_000
    check(
        share < IOSupervisor.peerCongestionByteCount && 3 * share > IOSupervisor.pauseAboveByteCount,
        "three shares cross the pause without any one crossing the peer threshold",
    )
    var crowd: [HarnessPeer] = []
    for peerID: UInt64 in 10 ... 12 {
        let member = HarnessPeer(peerID: peerID)
        member.supervisor = supervisor
        member.acknowledgesOutput = false
        harnessQueue.sync { supervisor.register(member) }
        check(replyCode(request(supervisor, from: member, .hello)) == .success, "peer \(peerID) says hello")
        // No newlines: the PTY would turn each into two bytes and carry a
        // share past the per-peer threshold.
        let opened = request(supervisor, from: member, .openSession) { message in
            let command = xpc_array_create(nil, 0)
            for argument in ["/bin/sh", "-c", "head -c \(share) /dev/zero | tr '\\0' x; sleep 30"] {
                xpc_array_append_value(command, xpc_string_create(argument))
            }
            xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
        }
        check(replyCode(opened) == .success, "peer \(peerID) opens a session under the threshold")
        crowd.append(member)
    }
    check(
        waitUntil(5) { crowd.reduce(0) { $0 + $1.outputByteCount() } > IOSupervisor.pauseAboveByteCount },
        "together the peers pass the pause (\(crowd.map { $0.outputByteCount() }))",
    )
    check(
        crowd.allSatisfy { $0.outputByteCount() < IOSupervisor.peerCongestionByteCount },
        "while none holds enough for a timer of its own (\(crowd.map { $0.outputByteCount() }))",
    )
    check(
        waitUntil(6) { crowd.allSatisfy(\.wasCut) },
        "every peer holding the socket shut is cut (\(crowd.map { $0.cutReason ?? "not cut" }))",
    )
    let afterCrowd = HarnessPeer(peerID: 13)
    afterCrowd.supervisor = supervisor
    harnessQueue.sync { supervisor.register(afterCrowd) }
    check(
        replyCode(request(supervisor, from: afterCrowd, .hello)) == .success,
        "and the socket is read again — a new peer is answered",
    )
    if let listed = request(supervisor, from: afterCrowd, .listSessions),
       let rows = xpc_dictionary_get_value(listed, iGhostVTWireKey.sessions)
    {
        for index in 0 ..< xpc_array_get_count(rows) {
            let id = xpc_dictionary_get_uint64(xpc_array_get_value(rows, index), iGhostVTWireKey.sessionID)
            _ = request(supervisor, from: afterCrowd, .closeSession) {
                xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, id)
            }
        }
    }
    _ = waitUntil {
        let listed = request(supervisor, from: afterCrowd, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
            .map { xpc_array_get_count($0) } == 0
    }

    // The other direction. A paste arrives as back-to-back messages at mach
    // speed and leaves at the socket's; what the socket has not taken sits
    // in this process, the one under the jetsam limit. Past the mark every
    // peer is held back, and let go once the child has drained it.
    print("proxy input backpressure")
    let paster = HarnessPeer(peerID: 14)
    paster.supervisor = supervisor
    harnessQueue.sync { supervisor.register(paster) }
    check(replyCode(request(supervisor, from: paster, .hello)) == .success, "a pasting peer says hello")
    let sink = request(supervisor, from: paster, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "stty raw -echo; exec sleep 30"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let sinkID = sink.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(sink) == .success && sinkID > 0, "a session that never reads opens")
    Thread.sleep(forTimeInterval: 0.5)
    let burstChunk = Data(repeating: UInt8(ascii: "x"), count: iGhostVTProtocol.inputChunkByteCount)
    let burstChunkCount = 4
    check(
        burstChunkCount * burstChunk.count > IOSupervisor.inputPauseAboveByteCount
            && burstChunkCount * burstChunk.count < iGhostVTProtocol.sessionPendingInputByteCount,
        "the burst passes the input pause and stays under the session's own cap",
    )
    // One block on the control queue, as libxpc delivers a queued paste: the
    // socket's write source cannot run between the messages.
    harnessQueue.sync {
        for _ in 0 ..< burstChunkCount {
            let message = makeRequest(.write) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sinkID)
                burstChunk.withUnsafeBytes {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count)
                }
            }
            supervisor.forward(from: paster, message: message, wantsReply: false) { _ in }
        }
    }
    check(paster.timesSuspended > 0, "the peer is suspended while the socket holds the paste")
    check(observer.timesSuspended > 0, "and so is every other peer")
    check(waitUntil(10) { paster.isBalanced && observer.isBalanced }, "and resumed once the child has drained it")
    check(harnessQueue.sync { !supervisor.isInputPaused }, "the supervisor records the pause as over")
    check(
        replyCode(request(supervisor, from: paster, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sinkID)
        }) == .success,
        "the sink session closes",
    )
    _ = waitUntil { listedRow(supervisor, from: paster, sessionID: sinkID) == nil }

    // The child dies: peers are cut, pending replies fail, a new child
    // comes up and serves.
    print("proxy child replacement")
    let bystander = HarnessPeer(peerID: 5)
    bystander.supervisor = supervisor
    harnessQueue.sync { supervisor.register(bystander) }
    check(replyCode(request(supervisor, from: bystander, .hello)) == .success, "a bystander says hello")
    let doomed = request(supervisor, from: bystander, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let doomedID = doomed.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(
        replyCode(doomed) == .success
            && setAttributes(supervisor, from: bystander, sessionID: doomedID, lock) == .success,
        "a session with attributes is held when io dies",
    )
    kill(firstChild, SIGKILL)
    check(waitUntil { bystander.wasCut }, "a peer is cut when io dies (\(bystander.cutReason ?? "not cut"))")
    check(
        waitUntil(5) { supervisor.childProcessID > 0 && supervisor.childProcessID != firstChild },
        "a replacement io is spawned",
    )
    let replacement = HarnessPeer(peerID: 6)
    replacement.supervisor = supervisor
    harnessQueue.sync { supervisor.register(replacement) }
    check(
        waitUntil(5) { replyCode(request(supervisor, from: replacement, .hello, timeout: 1)) == .success },
        "the replacement answers",
    )
    let afterCrash = request(supervisor, from: replacement, .listSessions)
    check(
        afterCrash.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
            .map { xpc_array_get_count($0) } == 0,
        "the replacement starts empty",
    )

    // Shutdown: refused while something is held, followed when nothing is.
    print("proxy shutdown")
    let held = request(supervisor, from: replacement, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let heldID = held.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(held) == .success, "a session opens on the replacement")
    check(
        attributes(in: listedRow(supervisor, from: replacement, sessionID: heldID)) == [:],
        "with no attributes left over from before the crash",
    )
    check(heldID != doomedID, "the replacement does not hand out the dead session's id again (\(doomedID) → \(heldID))")
    check(
        setAttributes(supervisor, from: replacement, sessionID: doomedID, lock) == .unknownSession,
        "and the dead session's id names nothing",
    )
    // What a tab does after the crash: attach to the id it kept.
    let returning = HarnessPeer(peerID: 15)
    returning.supervisor = supervisor
    harnessQueue.sync { supervisor.register(returning) }
    _ = request(supervisor, from: returning, .hello)
    let staleAttach = request(supervisor, from: returning, .attachSession) {
        xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, doomedID)
    }
    check(
        replyCode(staleAttach) == .unknownSession,
        "an attach to the dead session's id is refused, not handed the new session",
    )
    check(
        replyCode(request(supervisor, from: replacement, .shutdown)) == .sessionBusy,
        "shutdown with a session held is busy",
    )
    check(
        replyCode(request(supervisor, from: replacement, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, heldID)
        }) == .success,
        "the held session closes",
    )
    _ = waitUntil {
        let listed = request(supervisor, from: replacement, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
            .map { xpc_array_get_count($0) } == 0
    }
    let lastChild = supervisor.childProcessID
    check(
        replyCode(request(supervisor, from: replacement, .shutdown)) == .success,
        "shutdown with nothing held succeeds",
    )
    check(waitUntil { shutdownFollowed }, "the proxy follows io's exit after shutdown")
    check(waitUntil { kill(lastChild, 0) != 0 || supervisor.childProcessID == 0 }, "io is gone after shutdown")

    runSpawnPacingTest()
    runIdleExitTest(ioBinary: ioBinary)
}

/// The demand-launched daemon leaves on its own: with no peer for
/// `idleExitDelay` it asks the child to exit, which the child refuses while
/// it holds a session and grants once it holds nothing — and the proxy
/// follows. A peer in between keeps it.
func runIdleExitTest(ioBinary: String) {
    print("proxy idle exit")
    IOSupervisor.idleExitDelay = .milliseconds(300)
    defer { IOSupervisor.idleExitDelay = .seconds(3600) }
    let supervisor = IOSupervisor(queue: harnessQueue, executablePath: ioBinary)
    var exited = false
    supervisor.onShutdownExit = { exited = true }
    var started = false
    harnessQueue.sync {
        started = (try? supervisor.start()) != nil
    }
    check(started, "an idle-test io spawns")
    guard started else { return }

    let peer = HarnessPeer(peerID: 1)
    peer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(peer) }
    _ = request(supervisor, from: peer, .hello)
    Thread.sleep(forTimeInterval: 0.8)
    check(!exited, "a connected peer keeps the daemon")
    let held = request(supervisor, from: peer, .openSession) { message in
        let command = xpc_array_create(nil, 0)
        for argument in ["/bin/sh", "-c", "exec cat"] {
            xpc_array_append_value(command, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
    }
    let heldID = held.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.sessionID) } ?? 0
    check(replyCode(held) == .success, "a session opens")
    harnessQueue.sync { supervisor.peerGone(peer.peerID) }
    Thread.sleep(forTimeInterval: 1.2)
    let child = supervisor.childProcessID
    check(!exited && child > 0 && kill(child, 0) == 0, "a held session keeps the daemon with no peer")

    let closer = HarnessPeer(peerID: 2)
    closer.supervisor = supervisor
    harnessQueue.sync { supervisor.register(closer) }
    _ = request(supervisor, from: closer, .hello)
    check(
        replyCode(request(supervisor, from: closer, .closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, heldID)
        }) == .success,
        "the held session closes",
    )
    _ = waitUntil {
        let listed = request(supervisor, from: closer, .listSessions)
        return listed.flatMap { xpc_dictionary_get_value($0, iGhostVTWireKey.sessions) }
            .map { xpc_array_get_count($0) } == 0
    }
    harnessQueue.sync { supervisor.peerGone(closer.peerID) }
    check(waitUntil(5) { exited }, "with no peer and nothing held the daemon exits by itself")
    check(waitUntil { kill(child, 0) != 0 }, "and io is gone")
}

/// A respawn is paced by the last *attempt*. Keyed on the last child that
/// came up, a spawn that kept failing after a child that had lived past
/// `respawnDelay` was retried with no delay at all — the control queue
/// spinning on `posix_spawn` until the path came back.
func runSpawnPacingTest() {
    print("proxy respawn pacing")
    var template = Array("/private/tmp/ighostvt-harness-io.XXXXXX".utf8CString)
    guard let directory = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) })
        .map({ String(cString: $0) })
    else {
        check(false, "a directory for the stand-in io is created")
        return
    }
    let script = directory + "/ighostvtd-io"
    defer {
        unlink(script)
        rmdir(directory)
    }
    func install(_ body: String) {
        try? ("#!/bin/sh\n" + body + "\n").write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
    }
    // A stand-in that outlives the pacing window, so its exit reads as a
    // healthy child's, and that is gone from the path by the time it does.
    install("sleep 3")
    let supervisor = IOSupervisor(queue: harnessQueue, executablePath: script)
    var started = false
    harnessQueue.sync {
        started = (try? supervisor.start()) != nil
    }
    check(started, "the stand-in io spawns")
    guard started else { return }
    unlink(script)
    check(waitUntil(6) { harnessQueue.sync { !supervisor.isRunning } }, "the stand-in exits")
    // The link closes before the child is reaped and the respawn attempted;
    // give that attempt its moment to fail before the path comes back.
    Thread.sleep(forTimeInterval: 0.5)
    let restoredAt = Date()
    install("exec sleep 30")
    let cameUp = waitUntil(6) { harnessQueue.sync { supervisor.isRunning } }
    let waited = Date().timeIntervalSince(restoredAt)
    check(cameUp, "a respawn that failed is tried again")
    check(
        waited > 0.5,
        "a full delay after the failed attempt, not at once (came up \(String(format: "%.2f", waited))s after the path returned)",
    )
    guard cameUp else { return }
    let standIn = supervisor.childProcessID
    unlink(script)
    kill(standIn, SIGKILL)
    _ = waitUntil { harnessQueue.sync { !supervisor.isRunning } }
}

/// `uploadFile`: a file copied in parts, refused out of order, resumed
/// from another peer as a link that dropped would, and given up.
func runUploadTests(_ supervisor: IOSupervisor, first: HarnessPeer, second: HarnessPeer) {
    print("uploads")
    func begin(_ name: String, size: UInt64) -> xpc_object_t? {
        request(supervisor, from: first, .uploadFile) { message in
            xpc_dictionary_set_string(message, iGhostVTWireKey.fileName, name)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.fileSize, size)
        }
    }
    func part(_ from: HarnessPeer, _ id: UInt64, offset: UInt64, _ bytes: [UInt8]) -> xpc_object_t? {
        request(supervisor, from: from, .uploadFile) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.offset, offset)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count) }
        }
    }
    func ask(_ from: HarnessPeer, _ id: UInt64) -> xpc_object_t? {
        request(supervisor, from: from, .uploadFile) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
        }
    }

    let content = (0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let begun = begin("shot 1/2\n.png", size: UInt64(content.count))
    check(replyCode(begun) == .success, "an upload begins")
    guard let begun else { return }
    let id = xpc_dictionary_get_uint64(begun, iGhostVTWireKey.upload)
    let path = xpc_dictionary_get_string(begun, iGhostVTWireKey.path).map { String(cString: $0) } ?? ""
    check(id != 0 && path.hasPrefix("/"), "the reply names the upload and an absolute path (\(path))")
    check(
        (path as NSString).lastPathComponent == "shot 1_2_.png",
        "a separator and a control in the name become _ (\((path as NSString).lastPathComponent))",
    )

    let half = 128 * 1024
    let firstPart = part(first, id, offset: 0, Array(content[0 ..< half]))
    check(replyCode(firstPart) == .success, "the first part is taken")
    check(
        firstPart.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(half),
        "and the reply says how much is there",
    )
    let skipped = part(first, id, offset: UInt64(half + 10), Array(content[half + 10 ..< half + 20]))
    check(replyCode(skipped) == .invalidRequest, "a part past what is there is refused")
    check(
        skipped.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(half),
        "with where to carry on",
    )
    // A part the host already has — one the old link sent, landing after
    // the new link asked — is taken without writing anything again, and
    // one that overlaps writes only its new end.
    let repeated = part(first, id, offset: 0, Array(content[0 ..< 10]))
    check(
        replyCode(repeated) == .success
            && repeated.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(half),
        "a part already there is taken as it stands",
    )
    let overlapping = part(first, id, offset: UInt64(half - 100), Array(content[(half - 100) ..< (half + 100)]))
    check(
        replyCode(overlapping) == .success
            && overlapping.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(half + 100),
        "a part that overlaps writes only what is new",
    )

    // Another peer — the link that came back after a drop — asks, then
    // finishes it.
    let asked = ask(second, id)
    check(
        replyCode(asked) == .success && asked.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(half + 100),
        "another peer asks how much is there",
    )
    // The new link starts a little behind, as it does when the old link's
    // parts land after the question.
    var offset = half - 5000
    while offset < content.count {
        let end = min(offset + 64 * 1024, content.count)
        guard replyCode(part(second, id, offset: UInt64(offset), Array(content[offset ..< end]))) == .success else {
            check(false, "a resumed part at \(offset) is taken")
            return
        }
        offset = end
    }
    let written = FileManager.default.contents(atPath: path)
    check(written == Data(content), "the file on disk is every byte, in order (\(written?.count ?? -1))")
    let done = ask(first, id)
    check(
        replyCode(done) == .success
            && done.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.offset) } == UInt64(content.count),
        "a finished upload still answers with its size, for a client whose last reply was lost",
    )
    check(
        replyCode(part(second, id, offset: UInt64(content.count - 10), Array(content[(content.count - 10)...]))) == .success,
        "a last part sent again after the reply was lost is taken as done",
    )
    check(FileManager.default.contents(atPath: path) == Data(content), "and changes nothing")

    // Offsets are the client's: any value at all is answered, never trapped
    // on — an overflow here would take io, and every shell, down with it.
    check(
        replyCode(part(first, id, offset: UInt64.max - 1, [1, 2, 3])) == .unknownSession,
        "a finished upload answers an offset near the top of the range without trapping",
    )
    let edge = begin("edge.bin", size: 100)
    let edgeID = edge.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.upload) } ?? 0
    check(
        replyCode(part(first, edgeID, offset: UInt64.max - 1, [1, 2, 3])) == .invalidRequest,
        "a running upload refuses such an offset, and io is still there to say so",
    )
    check(
        replyCode(part(first, edgeID, offset: 0, Array(repeating: 7, count: 101))) == .invalidRequest,
        "a part past the declared size is refused",
    )

    // A begin sent again — its answer lost — finds the same upload.
    let chosen: UInt64 = 0x1234_5678_9ABC
    func beginAs(_ id: UInt64, _ name: String, size: UInt64) -> xpc_object_t? {
        request(supervisor, from: second, .uploadFile) { message in
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
            xpc_dictionary_set_string(message, iGhostVTWireKey.fileName, name)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.fileSize, size)
        }
    }
    let firstBegin = beginAs(chosen, "again.txt", size: 10)
    let secondBegin = beginAs(chosen, "again.txt", size: 10)
    let pathOf = { (reply: xpc_object_t?) in
        reply.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.path) }.map { String(cString: $0) }
    }
    check(
        replyCode(firstBegin) == .success
            && firstBegin.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.upload) } == chosen,
        "a client may choose the upload's id",
    )
    check(
        replyCode(secondBegin) == .success && pathOf(secondBegin) == pathOf(firstBegin),
        "and the same begin again answers the same upload",
    )
    check(
        replyCode(beginAs(chosen, "other.txt", size: 10)) == .invalidRequest,
        "a begin under that id for another file is refused",
    )
    _ = part(second, chosen, offset: 0, Array("0123456789".utf8))
    check(
        replyCode(beginAs(chosen, "again.txt", size: 10)) == .success,
        "a begin repeated after the upload finished still answers",
    )

    let tooBig = begin("big", size: iGhostVTProtocol.maximumUploadByteCount + 1)
    check(replyCode(tooBig) == .invalidRequest, "a file past the limit is refused")

    let abandoned = begin("partial.bin", size: 1000)
    let abandonedID = abandoned.map { xpc_dictionary_get_uint64($0, iGhostVTWireKey.upload) } ?? 0
    let abandonedPath = abandoned.flatMap { xpc_dictionary_get_string($0, iGhostVTWireKey.path) }.map { String(cString: $0) } ?? ""
    _ = part(first, abandonedID, offset: 0, [1, 2, 3])
    check(FileManager.default.fileExists(atPath: abandonedPath), "a partial file is there while it uploads")
    check(
        replyCode(request(supervisor, from: second, .shutdown)) == .sessionBusy,
        "an upload in progress holds the io process open",
    )
    _ = request(supervisor, from: first, .uploadFile) { message in
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, abandonedID)
        xpc_dictionary_set_bool(message, iGhostVTWireKey.cancel, true)
    }
    check(!FileManager.default.fileExists(atPath: abandonedPath), "a cancelled upload leaves no file")
    check(replyCode(ask(first, abandonedID)) == .unknownSession, "and is no longer known")
    check(replyCode(ask(first, 12345)) == .unknownSession, "an upload never begun is unknown")
    for cleanup in [path, pathOf(firstBegin) ?? ""] where !cleanup.isEmpty {
        try? FileManager.default.removeItem(atPath: (cleanup as NSString).deletingLastPathComponent)
    }
    _ = request(supervisor, from: first, .uploadFile) { message in
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, edgeID)
        xpc_dictionary_set_bool(message, iGhostVTWireKey.cancel, true)
    }
}
