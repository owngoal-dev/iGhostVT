import Foundation

// Tests for the clean-room ZMODEM core (iGhostVT/Backend/Zmodem). No daemon
// and no UIKit in the loop: the CRCs, the frame codec, the detector, and the
// two state machines driven against each other over in-memory pipes. The
// loopback is the strong one — `ZmodemSender` plays `sz`, `ZmodemReceiver`
// plays `rz`, and a file that comes out the other end byte-for-byte exercises
// both halves at once.

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

// MARK: CRC vectors

print("zmodem: CRC")
// CRC-16/CCITT over "123456789" with no augmentation is 0x29B1; ZMODEM augments
// with two zero bytes, which advances it to a different, well-defined value —
// assert it is stable and that a single bit-flip changes it.
let crc16a = ZmodemCRC.crc16(Array("123456789".utf8))
let crc16b = ZmodemCRC.crc16(Array("123456780".utf8))
check(crc16a != crc16b, "CRC-16 distinguishes a one-byte change")
check(ZmodemCRC.crc16([]) == ZmodemCRC.crc16([]), "CRC-16 is deterministic")
// Captured from real lrzsz over a PTY: these exact CRCs are what rz/sz put on
// the wire for a ZRPOS(0) and a ZRINIT(caps 0x23) hex header. Guards against
// re-introducing the augmentation bug that made every real header fail.
check(ZmodemCRC.crc16([0x09, 0, 0, 0, 0]) == 0xA87C, "CRC-16 matches real lrzsz ZRPOS header (0xA87C)")
check(ZmodemCRC.crc16([0x01, 0, 0, 0, 0x23]) == 0xBE50, "CRC-16 matches real lrzsz ZRINIT header (0xBE50)")
// CRC-32 of "123456789" is the standard 0xCBF43926.
check(ZmodemCRC.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC-32 matches the known vector")

// MARK: Header round-trip

print("zmodem: header codec")
func parseOne(_ bytes: [UInt8]) -> [ZParserEvent] {
    let parser = ZmodemParser()
    var events: [ZParserEvent] = []
    parser.onEvent = { events.append($0) }
    parser.feed(bytes)
    return events
}

do {
    let events = parseOne(ZmodemEncoder.hexHeader(.rinit, 0, 0, 0, 0x23))
    if case let .header(header)? = events.first, header.type == .rinit, header.p3 == 0x23 {
        check(true, "hex ZRINIT header round-trips with its capability byte")
    } else {
        check(false, "hex ZRINIT header round-trips with its capability byte")
    }
}

do {
    let events = parseOne(ZmodemEncoder.hexHeader(.rpos, 0x34, 0x12, 0, 0))
    if case let .header(header)? = events.first, header.type == .rpos, header.position == 0x1234 {
        check(true, "hex ZRPOS carries a little-endian position")
    } else {
        check(false, "hex ZRPOS carries a little-endian position")
    }
}

do {
    // A ZDATA bin32 header whose position bytes include control values that
    // must be ZDLE-escaped on the wire (0x18, 0x11).
    let events = parseOne(ZmodemEncoder.bin32Header(.data, 0x18, 0x11, 0x13, 0x10))
    if case let .header(header)? = events.first, header.type == .data,
       header.p0 == 0x18, header.p1 == 0x11, header.p2 == 0x13, header.p3 == 0x10
    {
        check(true, "bin32 ZDATA header survives ZDLE escaping of its bytes")
    } else {
        check(false, "bin32 ZDATA header survives ZDLE escaping of its bytes")
    }
}

// MARK: Subpacket / ZDLE round-trip over every byte value

print("zmodem: subpacket ZDLE escaping")
do {
    // A bin32 ZDATA header to set the parser's subpacket CRC width, then a
    // subpacket containing all 256 byte values.
    var stream = ZmodemEncoder.bin32Header(.data, 0, 0, 0, 0)
    let payload = (0 ... 255).map { UInt8($0) }
    stream += ZmodemEncoder.dataSubpacket32(payload, end: .end)
    let events = parseOne(stream)
    var recovered: [UInt8]?
    for event in events {
        if case let .data(bytes, end) = event, end == .end {
            recovered = bytes
        }
    }
    check(recovered == payload, "every byte value survives a subpacket round-trip")
}

do {
    // Bare XON/XOFF that a flow-controlled link might inject mid-frame must be
    // ignored by the parser, not taken as data (which would fail the CRC).
    var stream = ZmodemEncoder.bin32Header(.data, 0, 0, 0, 0)
    let payload: [UInt8] = Array("hello world".utf8)
    var sub = ZmodemEncoder.dataSubpacket32(payload, end: .end)
    // Splice XON (0x11) and XOFF (0x13) into the middle of the encoded subpacket.
    sub.insert(0x13, at: sub.count / 2)
    sub.insert(0x11, at: sub.count / 3)
    stream += sub
    let events = parseOne(stream)
    var recovered: [UInt8]?
    for event in events {
        if case let .data(bytes, _) = event {
            recovered = bytes
        }
    }
    check(recovered == payload, "bare XON/XOFF injected mid-subpacket are ignored")
}

// MARK: Detector

print("zmodem: trigger detection")
do {
    var detector = ZmodemDetector()
    let input = Array("hello\r\n".utf8) + [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30, 0x41]
    let result = detector.feed(input)
    check(result.trigger == .download, "ZRQINIT prefix is detected as a download")
    check(result.passthrough == input, "the whole detecting chunk is passed to the terminal in real time")
    check(result.parserBytes == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30, 0x41],
          "the trigger and trailing bytes are handed to the parser")
}

do {
    var detector = ZmodemDetector()
    let first = detector.feed([0x2A, 0x2A, 0x18])
    check(first.trigger == nil, "a split trigger is not yet detected on the first half")
    check(first.passthrough == [0x2A, 0x2A, 0x18], "partial-prefix bytes are rendered immediately, never withheld")
    let second = detector.feed([0x42, 0x30, 0x31])
    check(second.trigger == .upload, "the rest of a split trigger completes an upload detection")
    check(second.parserBytes == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31],
          "a split trigger is reassembled across chunks for the parser")
}

do {
    var detector = ZmodemDetector()
    let input = Array("a ** b ***".utf8)
    let result = detector.feed(input)
    check(result.trigger == nil, "stray asterisks do not false-trigger")
    check(result.passthrough == input, "non-trigger text is rendered verbatim, including a trailing prefix")
}

// MARK: Loopback — sender ↔ receiver

print("zmodem: end-to-end loopback")

final class MemoryWriter: ZmodemFileWriter, @unchecked Sendable {
    var files: [(name: String, data: [UInt8])] = []
    var completed: Bool?
    private var current: (name: String, data: [UInt8])?

    func beginFile(name: String, size _: UInt64?) -> Bool {
        current = (name, [])
        return true
    }

    func write(_ bytes: [UInt8]) {
        current?.data.append(contentsOf: bytes)
        writtenLock.lock()
        written += bytes.count
        writtenLock.unlock()
    }

    private let writtenLock = NSLock()
    private var written = 0
    var writtenSoFar: Int {
        writtenLock.lock()
        defer { writtenLock.unlock() }
        return written
    }

    func finishFile() {
        if let current {
            files.append(current)
        }
        current = nil
    }

    func finish(completed: Bool) {
        self.completed = completed
    }
}

final class MemorySource: ZmodemFileSource, @unchecked Sendable {
    private var queue: [(name: String, data: [UInt8])]
    var completed: Bool?

    init(_ files: [(name: String, data: [UInt8])]) {
        queue = files
    }

    func nextFile() -> ZmodemOutgoingFile? {
        guard !queue.isEmpty else { return nil }
        let file = queue.removeFirst()
        return ZmodemOutgoingFile(name: file.name, size: UInt64(file.data.count)) { offset, maxLength in
            let start = Int(offset)
            guard start < file.data.count else { return [] }
            let end = min(start + maxLength, file.data.count)
            return Array(file.data[start ..< end])
        }
    }

    func finish(completed: Bool) {
        self.completed = completed
    }
}

/// Runs `ZmodemSender` (as `sz`) against `ZmodemReceiver` (as `rz`) over two
/// byte queues and returns what the receiver wrote.
func loopback(_ files: [(name: String, data: [UInt8])]) -> (MemoryWriter, MemorySource) {
    var usToPeer: [UInt8] = []
    var peerToUs: [UInt8] = []

    let source = MemorySource(files)
    let writer = MemoryWriter()

    let sender = ZmodemSender(send: { usToPeer.append(contentsOf: $0) }, source: source)
    let receiver = ZmodemReceiver(send: { peerToUs.append(contentsOf: $0) }, writer: writer)

    let senderParser = ZmodemParser()
    senderParser.onEvent = { sender.handle($0) }
    let receiverParser = ZmodemParser()
    receiverParser.onEvent = { receiver.handle($0) }

    receiver.begin() // rz announces ZRINIT
    sender.begin() // sz sends ZFILE

    var guardCount = 0
    while !usToPeer.isEmpty || !peerToUs.isEmpty {
        guardCount += 1
        if guardCount > 1_000_000 {
            break
        }
        if !usToPeer.isEmpty {
            let bytes = usToPeer
            usToPeer.removeAll(keepingCapacity: true)
            receiverParser.feed(bytes)
        }
        if !peerToUs.isEmpty {
            let bytes = peerToUs
            peerToUs.removeAll(keepingCapacity: true)
            senderParser.feed(bytes)
        }
    }
    return (writer, source)
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0 ..< count {
        bytes[index] = UInt8.random(in: 0 ... 255)
    }
    return bytes
}

do {
    let payload = Array("The quick brown fox\r\njumps over the lazy dog.\n".utf8)
    let (writer, source) = loopback([("fox.txt", payload)])
    check(writer.files.count == 1 && writer.files.first?.name == "fox.txt", "loopback transfers the file name")
    check(writer.files.first?.data == payload, "loopback transfers a small text file intact")
    check(writer.completed == true, "receiver reports completion")
    check(source.completed == true, "sender reports completion")
}

do {
    // Binary data with control bytes, spanning several 8192-byte blocks and
    // not a clean multiple of the block size.
    let payload = randomBytes(8192 * 3 + 123)
    let (writer, _) = loopback([("blob.bin", payload)])
    check(writer.files.first?.data == payload, "loopback transfers a multi-block binary file intact")
}

do {
    let payload = randomBytes(8192) // exactly one block
    let (writer, _) = loopback([("exact.bin", payload)])
    check(writer.files.first?.data == payload, "loopback handles an exact-block-size file")
}

do {
    let (writer, _) = loopback([("empty.bin", [])])
    check(writer.files.first?.name == "empty.bin" && writer.files.first?.data.isEmpty == true,
          "loopback handles an empty file")
}

do {
    let a = randomBytes(5000)
    let b = Array("second file\n".utf8)
    let (writer, _) = loopback([("a.bin", a), ("b.txt", b)])
    check(writer.files.count == 2, "loopback transfers a batch of two files")
    check(writer.files.first?.data == a && writer.files.last?.data == b, "both files in the batch arrive intact")
}

// The pill follows the bytes even when they arrive in bursts: the engine
// throttles progress to ~10 Hz, and once dropped each burst's last figure,
// leaving the bar on a stale value until the next burst (seconds, over a
// slow relay).
print("zmodem: progress reaches the pill between bursts")

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

do {
    let payload = randomBytes(60000)
    let fromEngine = Box<[UInt8]>([])
    let lastState = Box<ZmodemTransferInfo?>(nil)
    let writer = MemoryWriter()
    let engine = ZmodemEngine(
        sink: { bytes in fromEngine.with { $0.append(contentsOf: bytes) } },
        passthrough: { _ in },
        makeWriter: { writer },
        requestSource: { $0(nil) },
        onState: { info in lastState.with { if let info { $0 = info } } },
    )
    var toEngine: [UInt8] = []
    let sender = ZmodemSender(send: { toEngine.append(contentsOf: $0) }, source: MemorySource([("burst.bin", payload)]))
    let senderParser = ZmodemParser()
    senderParser.onEvent = { sender.handle($0) }

    // sz announces itself; the engine answers ZRINIT, and the sender, on
    // hearing it, offers the file and streams once the engine asks.
    engine.ingest(Data(Array("rz\r".utf8) + ZmodemEncoder.hexHeader(.rqinit)))
    sender.begin()
    func pump(until done: () -> Bool, limit: Int) {
        for _ in 0 ..< 400 {
            usleep(5000)
            let back = fromEngine.with { bytes -> [UInt8] in defer { bytes.removeAll() }; return bytes }
            if !back.isEmpty { senderParser.feed(back) }
            if !toEngine.isEmpty {
                let chunk = Array(toEngine.prefix(limit))
                toEngine.removeFirst(chunk.count)
                engine.ingest(Data(chunk))
            }
            if done() { return }
        }
    }
    // First burst: about a third of the file, then nothing more arrives.
    pump(until: { writer.writtenSoFar >= 20000 }, limit: 4096)
    let heldBack = toEngine.count
    usleep(400_000)
    let shown = lastState.with { $0?.transferred ?? 0 }
    let written = writer.writtenSoFar
    check(heldBack > 0, "the first burst stops short of the whole file (\(heldBack) bytes held back)")
    check(
        written >= 20000 && shown == UInt64(written),
        "between bursts the pill shows everything received so far (\(shown) of \(written))",
    )
    // The rest arrives; the transfer completes intact.
    pump(until: { writer.completed != nil }, limit: 1 << 20)
    check(writer.files.first?.data == payload, "the burst-split download arrives intact")
    engine.reset()
}

// A transfer in the replay, or still streaming after a dropped link, must
// never be drawn: it is ZDLE-escaped binary that covers the screen and
// retitles the tab.
print("zmodem: transfers are kept off the screen outside an engine")

/// What `sz` writes for one file, start to end, from a real sender.
func szOutput(_ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = Array("rz\r".utf8) + ZmodemEncoder.hexHeader(.rqinit)
    var toSender: [UInt8] = []
    let source = MemorySource([("f.bin", payload)])
    let sender = ZmodemSender(send: { out.append(contentsOf: $0) }, source: source)
    let receiver = ZmodemReceiver(send: { toSender.append(contentsOf: $0) }, writer: MemoryWriter())
    let senderParser = ZmodemParser()
    senderParser.onEvent = { sender.handle($0) }
    let receiverParser = ZmodemParser()
    receiverParser.onEvent = { receiver.handle($0) }
    var fed = 0
    receiver.begin()
    sender.begin()
    for _ in 0 ..< 100_000 {
        if fed < out.count {
            let chunk = Array(out[fed...])
            fed = out.count
            receiverParser.feed(chunk)
        }
        if !toSender.isEmpty {
            let chunk = toSender
            toSender.removeAll()
            senderParser.feed(chunk)
        }
        if fed == out.count, toSender.isEmpty { break }
    }
    return out
}

do {
    let before = Array("$ sz f.bin\r\n".utf8)
    let after = Array("$ echo next\r\nnext\r\n$ ".utf8)
    let transfer = szOutput(randomBytes(9000))
    let stripped = ZmodemStreamScanner.strip(before + transfer + after)
    check(stripped.removed, "a finished transfer in the replay is found")
    check(stripped.bytes == before + after, "and taken out, the output on either side kept (\(stripped.bytes.count) bytes)")
    check(!stripped.bytes.contains(0x18), "no ZDLE is left to draw")

    let cancel = [UInt8](repeating: 0x18, count: 10) + [UInt8](repeating: 0x08, count: 10)
    let cut = Array(transfer.prefix(transfer.count / 2))
    let aborted = ZmodemStreamScanner.strip(before + cut + cancel + after)
    check(aborted.bytes == before + after, "a cancelled transfer ends at its CAN run")
    let open = ZmodemStreamScanner.strip(before + cut)
    check(open.removed && open.bytes == before, "a transfer that never ended is taken out to the end")
    let plain = ZmodemStreamScanner.strip(before + after)
    check(!plain.removed && plain.bytes == before + after, "output without a transfer is left alone")
}

do {
    // The next link after one dropped mid-download: the sender is still
    // streaming. The engine swallows it, tells the sender to stop, and
    // draws what comes after the sender's own cancel.
    let shown = Box<[UInt8]>([])
    let sent = Box<[UInt8]>([])
    let engine = ZmodemEngine(
        sink: { bytes in sent.with { $0.append(contentsOf: bytes) } },
        passthrough: { bytes in shown.with { $0.append(contentsOf: bytes) } },
        makeWriter: { MemoryWriter() },
        requestSource: { $0(nil) },
        onState: { _ in },
    )
    engine.discardInterruptedTransfer()
    let transfer = szOutput(randomBytes(20000))
    let middle = Array(transfer[(transfer.count / 3) ..< (transfer.count / 2)])
    engine.ingest(Data(middle))
    usleep(100_000)
    check(shown.with { $0 }.isEmpty, "the stream after the link came back is not drawn")
    check(
        sent.with { $0 } == ZmodemEncoder.cancelSequence(),
        "the sender still streaming is told to stop (\(sent.with { $0.count }) bytes sent)",
    )
    engine.ingest(Data(Array(transfer[(transfer.count / 2)...].prefix(3000))))
    let cancel = [UInt8](repeating: 0x18, count: 10) + [UInt8](repeating: 0x08, count: 10)
    engine.ingest(Data(cancel + Array("\r\n$ ".utf8)))
    usleep(100_000)
    check(shown.with { $0 } == Array("\r\n$ ".utf8), "what follows the sender's cancel is drawn again")
    engine.ingest(Data(Array("ls\r\n".utf8)))
    usleep(100_000)
    check(shown.with { $0 } == Array("\r\n$ ls\r\n".utf8), "and output flows as before")
}

do {
    // The sender gave up before the link came back: the first thing to
    // arrive is the shell. Nothing is swallowed and nothing is sent — a
    // cancel would reach the shell as keystrokes.
    let shown = Box<[UInt8]>([])
    let sent = Box<[UInt8]>([])
    let engine = ZmodemEngine(
        sink: { bytes in sent.with { $0.append(contentsOf: bytes) } },
        passthrough: { bytes in shown.with { $0.append(contentsOf: bytes) } },
        makeWriter: { MemoryWriter() },
        requestSource: { $0(nil) },
        onState: { _ in },
    )
    engine.discardInterruptedTransfer()
    engine.ingest(Data(Array("$ 你好\r\n".utf8)))
    usleep(100_000)
    check(shown.with { $0 } == Array("$ 你好\r\n".utf8), "a shell already back at its prompt is drawn at once")
    check(sent.with { $0 }.isEmpty, "and sent nothing")
}

// A congested link holds a whole file in its buffers; `sz` gives up waiting
// for the ZRINIT that answers its ZEOF and exits before the file is through.
print("zmodem: a sender that leaves after its last ZEOF")
do {
    let payload = randomBytes(40000)
    let conversation = szOutput(payload)
    let zfin: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x38]
    var finAt = conversation.count
    for index in 0 ... (conversation.count - zfin.count) where Array(conversation[index ..< index + zfin.count]) == zfin {
        finAt = index
        break
    }
    func receive(_ bytes: ArraySlice<UInt8>) -> (ZmodemReceiver, MemoryWriter) {
        let writer = MemoryWriter()
        let receiver = ZmodemReceiver(send: { _ in }, writer: writer)
        let parser = ZmodemParser()
        parser.onEvent = { receiver.handle($0) }
        receiver.begin()
        parser.feed(Array(bytes))
        return (receiver, writer)
    }
    let (whole, wholeWriter) = receive(conversation[..<finAt])
    check(whole.isAwaitingSenderAfterCompleteFiles, "a file that ended whole waits for the sender's ZFIN")
    check(whole.senderWentQuiet(), "a sender gone after it is a finished transfer")
    check(wholeWriter.completed == true && wholeWriter.files.first?.data == payload, "with the file kept, every byte")
    let (cut, cutWriter) = receive(conversation[..<(finAt / 2)])
    check(!cut.senderWentQuiet(), "a sender gone mid-file is a stall")
    check(cutWriter.completed == nil, "and keeps nothing")
}

// MARK: Result

if failures.isEmpty {
    print("\nzmodem: all checks passed")
    exit(0)
} else {
    print("\nzmodem: \(failures.count) FAILURE(S)")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
