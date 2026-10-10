import CryptoKit
import Darwin
import Dispatch
import Foundation
@preconcurrency import XPC

// The scenarios `lab.sh scenario NAME PROFILE` runs. Each opens sessions on
// this Mac's host as a paired device would, checks one thing a person would
// notice — output that does not arrive, keys that do not get through, a
// paste cut short, a tab that cannot connect — and prints `RESULT ok` or
// `RESULT FAILED` with the figures behind it. The host is this Mac, so the
// programs it runs stamp their output with a clock this process shares.

/// One session on one link, its output gathered.
final class LabSession: @unchecked Sendable {
    let link: LabLink
    private(set) var id: UInt64 = 0
    private let lock = NSLock()
    private var buffer = Data()
    private var arrivals: [(Date, Int)] = []
    private(set) var exitCode: Int64?

    init(link: LabLink) {
        self.link = link
    }

    var output: Data {
        lock.withLock { buffer }
    }

    var text: String {
        String(decoding: output, as: UTF8.self)
    }

    func received(_ bytes: Data) {
        lock.withLock {
            buffer.append(bytes)
            arrivals.append((Date(), buffer.count))
        }
    }

    func exited(_ code: Int64) {
        lock.withLock { exitCode = code }
    }

    /// Opens `argv` on the host, attached to this link.
    func open(_ argv: [String], columns: UInt64 = 120, rows: UInt64 = 40) -> Bool {
        let open = message(.openSession)
        xpc_dictionary_set_uint64(open, iGhostVTWireKey.columns, columns)
        xpc_dictionary_set_uint64(open, iGhostVTWireKey.rows, rows)
        let array = xpc_array_create(nil, 0)
        for argument in argv {
            xpc_array_append_value(array, xpc_string_create(argument))
        }
        xpc_dictionary_set_value(open, iGhostVTWireKey.command, array)
        guard let reply = link.request(open, timeout: 30), code(of: reply) == .success else { return false }
        id = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
        return true
    }

    /// Attaches to a session this device held on an earlier link; the
    /// replay is the start of the output.
    func attach(_ sessionID: UInt64, takeover: Bool = true) -> iGhostVTReplyCode? {
        let attach = message(.attachSession)
        xpc_dictionary_set_uint64(attach, iGhostVTWireKey.sessionID, sessionID)
        if takeover {
            xpc_dictionary_set_bool(attach, iGhostVTWireKey.takeover, true)
        }
        guard let reply = link.request(attach, timeout: 30) else { return nil }
        let answer = code(of: reply)
        if answer == .success {
            id = sessionID
            if let replay = data(iGhostVTWireKey.data, in: reply) {
                received(replay)
            }
        }
        return answer
    }

    func write(_ bytes: Data) {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = bytes.index(offset, offsetBy: iGhostVTProtocol.inputChunkByteCount, limitedBy: bytes.endIndex) ?? bytes.endIndex
            let write = message(.write)
            xpc_dictionary_set_uint64(write, iGhostVTWireKey.sessionID, id)
            setData(bytes[offset ..< end], iGhostVTWireKey.data, in: write)
            link.send(write)
            offset = end
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func close() {
        let close = message(.closeSession)
        xpc_dictionary_set_uint64(close, iGhostVTWireKey.sessionID, id)
        _ = link.request(close, timeout: 10)
    }

    /// Waits for `needle` in the output; how long it took, or nil.
    @discardableResult
    func wait(for needle: String, timeout: TimeInterval) -> TimeInterval? {
        let started = Date()
        let bytes = Data(needle.utf8)
        while Date().timeIntervalSince(started) < timeout {
            if output.range(of: bytes) != nil {
                return Date().timeIntervalSince(started)
            }
            usleep(5000)
        }
        return nil
    }

    func waitForExit(timeout: TimeInterval) -> Int64? {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let exitCode = lock.withLock({ exitCode }) {
                return exitCode
            }
            usleep(20000)
        }
        return nil
    }
}

/// Routes a link's events to its sessions.
func route(_ link: LabLink, _ sessions: @escaping () -> [LabSession]) {
    link.onEvent = { event in
        let sessionID = xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID)
        guard let session = sessions().first(where: { $0.id == sessionID }) else { return }
        switch xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) {
        case iGhostVTEvent.output.rawValue:
            if let bytes = data(iGhostVTWireKey.data, in: event) {
                session.received(bytes)
            }
        case iGhostVTEvent.sessionExit.rawValue:
            session.exited(xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))
        default:
            break
        }
    }
}

/// A link and one session on it, or the scenario fails.
func openOne(_ device: LabDevice, _ argv: [String]) -> LabSession {
    let link = connect(device)
    let session = LabSession(link: link)
    route(link) { [session] }
    link.onClosed = { reason in say("link closed: \(reason)") }
    guard session.open(argv) else { fail("openSession refused") }
    return session
}

let python = "/usr/bin/python3"

final class Verdict {
    private(set) var failures: [String] = []
    private var lines: [String] = []

    func check(_ condition: Bool, _ line: String) {
        lines.append("  \(condition ? "ok  " : "FAIL") \(line)")
        if !condition {
            failures.append(line)
        }
    }

    func note(_ line: String) {
        lines.append("       \(line)")
    }

    func finish() -> Int32 {
        print("")
        print("RESULT \(failures.isEmpty ? "ok" : "FAILED")")
        lines.forEach { print($0) }
        return failures.isEmpty ? 0 : 2
    }
}

func stats(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "none" }
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    return String(format: "median %.0f ms, p95 %.0f ms, max %.0f ms", median * 1000, p95 * 1000, sorted.last! * 1000)
}

/// Lines of `tick <n> <host time>` as they arrived: n → arrival delay.
func tickDelays(_ session: LabSession, arrivedAt: [Int: Date]) -> [Int: Double] {
    var delays: [Int: Double] = [:]
    for line in session.text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "tick", let n = Int(parts[1]), let stamp = Double(parts[2]),
              let arrived = arrivedAt[n] else { continue }
        delays[n] = arrived.timeIntervalSince1970 - stamp
    }
    return delays
}

/// Output that comes with no input: a program printing every `interval`
/// seconds, `count` times, and nothing typed. Every line must arrive, each
/// within `limit` of being printed.
func trickle(count: Int, interval: Double, limit: Double) -> Int32 {
    let verdict = Verdict()
    let device = loadDevice()
    let code = "import time\nfor i in range(\(count)):\n    print('tick', i, time.time(), flush=True)\n    time.sleep(\(interval))\nprint('end', flush=True)"
    let session = openOne(device, [python, "-u", "-c", code])
    var arrivedAt: [Int: Date] = [:]
    var seen = 0
    let deadline = Date().addingTimeInterval(Double(count) * interval + 120)
    while Date() < deadline, seen < count {
        if session.text.contains("tick \(seen) ") {
            arrivedAt[seen] = Date()
            say("tick \(seen) arrived")
            seen += 1
            continue
        }
        if session.link.isClosed {
            break
        }
        usleep(5000)
    }
    let delays = tickDelays(session, arrivedAt: arrivedAt)
    verdict.check(delays.count == count, "\(delays.count) of \(count) lines arrived with nothing typed")
    let late = delays.filter { $0.value > limit }
    verdict.check(late.isEmpty, "every line within \(Int(limit)) s of being printed (\(late.count) late)")
    verdict.note("delay: \(stats(Array(delays.values)))")
    verdict.check(!session.link.isClosed, "the link stayed up")
    if !session.link.isClosed {
        session.close()
        session.link.close()
    }
    return verdict.finish()
}

/// Keystrokes one at a time into `cat`, each waited for: the round trip a
/// person feels typing.
func echo(count: Int) -> Int32 {
    let verdict = Verdict()
    let session = openOne(loadDevice(), ["/bin/cat"])
    var times: [Double] = []
    var lost = 0
    for index in 0 ..< count {
        let token = "k\(index)z"
        let sent = Date()
        session.write(token + "\r")
        // The tty echoes it, and cat prints the line again.
        if session.wait(for: "\(token)\r\n\(token)", timeout: 15) != nil {
            times.append(Date().timeIntervalSince(sent))
        } else {
            lost += 1
            say("keystroke \(index) not echoed in 15 s")
            if session.link.isClosed {
                break
            }
        }
    }
    verdict.check(lost == 0 && times.count == count, "\(times.count) of \(count) lines echoed")
    verdict.note("round trip: \(stats(times))")
    verdict.check(!session.link.isClosed, "the link stayed up")
    if !session.link.isClosed {
        session.close()
        session.link.close()
    }
    return verdict.finish()
}

/// A program flooding output while the person types: the key must reach
/// it promptly however much output is queued the other way, and stopping
/// it must stop the flood.
func flood(seconds: Double) -> Int32 {
    let verdict = Verdict()
    let code = """
    import os, sys, threading, time
    # The flood holds the lock for each write, so the ACK line is never
    # spliced into the middle of one and its stamp stays readable.
    lock = threading.Lock()
    def reader():
        data = b''
        while True:
            chunk = os.read(0, 64)
            if not chunk:
                return
            data += chunk
            if b'STOP' in data:
                stamp = time.time()
                lock.acquire()
                os.write(1, b'\\nACK %f\\n' % stamp)
                os._exit(0)
    import tty; tty.setraw(0)
    threading.Thread(target=reader, daemon=True).start()
    line = ('x' * 200 + '\\n').encode()
    while True:
        with lock:
            os.write(1, line * 50)
    """
    let session = openOne(loadDevice(), [python, "-u", "-c", code])
    Thread.sleep(forTimeInterval: seconds)
    let sent = Date()
    let receivedBefore = session.output.count
    session.write("STOP")
    let exited = session.waitForExit(timeout: 120)
    let total = Date().timeIntervalSince(sent)
    // The exit can overtake the program's last output on its way here.
    if session.wait(for: "ACK ", timeout: 0) == nil, session.wait(for: "ACK ", timeout: 10) != nil {
        verdict.note("the ACK arrived after the exit event")
    }
    var inputDelay: Double?
    if let range = session.text.range(of: "ACK ") {
        let stamp = session.text[range.upperBound...].prefix { $0 != "\r" && $0 != "\n" }
        inputDelay = Double(stamp).map { $0 - sent.timeIntervalSince1970 }
    }
    verdict.note(String(format: "%.1f MiB of output before the key", Double(receivedBefore) / 1_048_576))
    verdict.check(inputDelay != nil, "the key reached the program")
    if let inputDelay {
        verdict.check(inputDelay < 5, String(format: "within 5 s of being typed (%.2f s)", inputDelay))
    }
    verdict.check(exited != nil, String(format: "the flood ended and its tail drained, %.1f s after the key", total))
    verdict.check(!session.link.isClosed, "the link stayed up")
    if !session.link.isClosed {
        if exited == nil {
            session.close()
        }
        session.link.close()
    }
    return verdict.finish()
}

/// A paste of `byteCount` bytes into a program reading raw: every byte
/// arrives, in order.
func paste(byteCount: Int) -> Int32 {
    let verdict = Verdict()
    let code = """
    import hashlib, os, sys, tty
    tty.setraw(0)
    want = \(byteCount)
    got = 0
    h = hashlib.sha256()
    while got < want:
        chunk = os.read(0, 65536)
        if not chunk:
            break
        h.update(chunk)
        got += len(chunk)
    print('\\r\\nPASTED %d %s' % (got, h.hexdigest()), flush=True)
    """
    let session = openOne(loadDevice(), [python, "-u", "-c", code])
    Thread.sleep(forTimeInterval: 0.5)
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 ".utf8)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for index in bytes.indices {
        bytes[index] = index % 80 == 79 ? 0x0D : alphabet[Int(generator.next() % UInt64(alphabet.count))]
    }
    let payload = Data(bytes)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let sent = Date()
    session.write(payload)
    let took = session.wait(for: "PASTED", timeout: 300)
    _ = session.wait(for: digest, timeout: 2)
    verdict.check(took != nil, String(format: "the program read the whole paste (%.1f s)", took ?? Date().timeIntervalSince(sent)))
    verdict.check(session.text.contains("PASTED \(byteCount) \(digest)"), "byte for byte (\(byteCount) bytes)")
    verdict.check(!session.link.isClosed, "the link stayed up")
    if !session.link.isClosed {
        session.close()
        session.link.close()
    }
    return verdict.finish()
}

/// The link dies mid-output (as a phone's does when it changes network),
/// a new one attaches to the session: nothing printed meanwhile is lost —
/// it is in the replay — and output carries on.
func reattach(cycles: Int) -> Int32 {
    let verdict = Verdict()
    let device = loadDevice()
    let total = cycles * 6 + 6
    let code = "import time\nfor i in range(\(total)):\n    print('tick', i, time.time(), flush=True)\n    time.sleep(0.5)\nprint('end', flush=True)\ntime.sleep(30)"
    var session = openOne(device, [python, "-u", "-c", code])
    let sessionID = session.id
    var seen = Set<Int>()
    func collect(_ session: LabSession) {
        for line in session.text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "tick", let n = Int(parts[1]) {
                seen.insert(n)
            }
        }
    }
    for cycle in 0 ..< cycles {
        Thread.sleep(forTimeInterval: 2)
        collect(session)
        say("cycle \(cycle): dropping the link without a word")
        session.link.frames.connection.forceCancel()
        Thread.sleep(forTimeInterval: 1)
        let attachStarted = Date()
        var attached: LabSession?
        var lastCode: iGhostVTReplyCode?
        while Date().timeIntervalSince(attachStarted) < 40, attached == nil {
            guard case let .success(link) = tryConnect(device, quiet: true) else {
                usleep(500_000)
                continue
            }
            let next = LabSession(link: link)
            route(link) { [next] }
            lastCode = next.attach(sessionID)
            if lastCode == .success {
                attached = next
            } else {
                link.close()
                usleep(500_000)
            }
        }
        guard let attached else {
            verdict.check(false, "cycle \(cycle): reattached (last answer \(String(describing: lastCode)))")
            return verdict.finish()
        }
        verdict.note(String(format: "cycle %d: reattached in %.2f s", cycle, Date().timeIntervalSince(attachStarted)))
        session = attached
    }
    _ = session.wait(for: "end", timeout: Double(total) + 30)
    collect(session)
    let missing = (0 ..< total).filter { !seen.contains($0) }
    verdict.check(missing.isEmpty, "every line arrived across \(cycles) reattach(es) (missing \(missing.prefix(10)))")
    session.close()
    session.link.close()
    return verdict.finish()
}

/// A window of tabs coming back at once — a launch, the app returning to
/// the foreground, the network coming back: `count` links dialled at the
/// same moment, each opening a session. Every one must get through.
func storm(count: Int) -> Int32 {
    let verdict = Verdict()
    let device = loadDevice()
    let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: count)
    results.initialize(repeating: 0)
    let times = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
    times.initialize(repeating: 0)
    let reasons = NSMutableArray()
    let group = DispatchGroup()
    let started = Date()
    for index in 0 ..< count {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            switch tryConnect(device, quiet: true) {
            case let .success(link):
                let session = LabSession(link: link)
                route(link) { [session] }
                if session.open(["/bin/cat"]), session.wait(for: "ready", timeout: 0) == nil {
                    session.write("ready\r")
                    if session.wait(for: "ready\r\nready", timeout: 20) != nil {
                        results[index] = 1
                        times[index] = Date().timeIntervalSince(started)
                    }
                    session.close()
                }
                link.close()
            case let .failure(error):
                reasons.add("\(index): \(error.reason)")
            }
        }
    }
    group.wait()
    let succeeded = results.reduce(0, +)
    verdict.check(succeeded == count, "\(succeeded) of \(count) tabs connected and echoed")
    verdict.note("slowest: \(String(format: "%.1f s", times.max() ?? 0))")
    for reason in reasons {
        verdict.note("\(reason)")
    }
    return verdict.finish()
}

/// A file dropped on a remote tab: `uploadFile`, begin, parts in order,
/// eight in flight, and the file on the host checked byte for byte.
func upload(byteCount: Int) -> Int32 {
    let verdict = Verdict()
    let link = connect(loadDevice())
    var bytes = [UInt8](repeating: 0, count: byteCount)
    arc4random_buf(&bytes, byteCount)
    let payload = Data(bytes)
    let digest = SHA256.hash(data: payload)
    let id = UInt64.random(in: 1 ... .max)
    let begin = message(.uploadFile)
    xpc_dictionary_set_uint64(begin, iGhostVTWireKey.upload, id)
    xpc_dictionary_set_string(begin, iGhostVTWireKey.fileName, "lab-upload.bin")
    xpc_dictionary_set_uint64(begin, iGhostVTWireKey.fileSize, UInt64(byteCount))
    guard let reply = link.request(begin), code(of: reply) == .success,
          let path = xpc_dictionary_get_string(reply, iGhostVTWireKey.path).map({ String(cString: $0) })
    else { fail("upload begin refused") }
    let started = Date()
    let chunk = iGhostVTProtocol.uploadChunkByteCount
    let window = DispatchSemaphore(value: 8)
    let lock = NSLock()
    var refused = 0
    var offset = 0
    while offset < byteCount {
        window.wait()
        let end = min(offset + chunk, byteCount)
        let part = message(.uploadFile)
        xpc_dictionary_set_uint64(part, iGhostVTWireKey.upload, id)
        xpc_dictionary_set_uint64(part, iGhostVTWireKey.offset, UInt64(offset))
        setData(payload[offset ..< end], iGhostVTWireKey.data, in: part)
        link.send(part) { reply in
            if code(of: reply) != .success {
                lock.withLock { refused += 1 }
            }
            window.signal()
        }
        offset = end
    }
    for _ in 0 ..< 8 {
        window.wait()
    }
    // A semaphore freed below its starting value traps.
    for _ in 0 ..< 8 {
        window.signal()
    }
    let took = Date().timeIntervalSince(started)
    let landed = FileManager.default.contents(atPath: path)
    verdict.check(refused == 0, "every part accepted (\(refused) refused)")
    verdict.check(landed.map { SHA256.hash(data: $0) == digest } ?? false, "the file on the host is the file sent (\(byteCount) bytes)")
    verdict.note(String(format: "%.1f s, %.0f KiB/s", took, Double(byteCount) / 1024 / took))
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    link.close()
    return verdict.finish()
}

/// sz with the link dropped `drops` times mid-file, as a phone changing
/// networks does: each time the engine keeps the download
/// (`suspendForLostLink`), a new link attaches to the session after
/// `outage` seconds, and the engine asks sz to go back to what arrived
/// (`resume`). The file must come out whole.
func szAcrossDrops(megabytes: Int, drops: Int, outage: Double) -> Int32 {
    let verdict = Verdict()
    let device = loadDevice()
    let path = (option("state") as NSString).appendingPathComponent("payload-\(megabytes)m.bin")
    if !FileManager.default.fileExists(atPath: path) {
        var bytes = [UInt8](repeating: 0, count: megabytes << 20)
        arc4random_buf(&bytes, bytes.count)
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
    }
    let expected = SHA256.hash(data: FileManager.default.contents(atPath: path)!).map { String(format: "%02x", $0) }.joined()
    let size = UInt64(megabytes << 20)
    let writer = HashingWriter()
    let lock = NSLock()
    final class State: @unchecked Sendable {
        var current: LabSession?
        var finishedOK: Bool?
    }
    let state = State()
    let engine = ZmodemEngine(
        sink: { bytes in lock.withLock { state.current }?.write(Data(bytes)) },
        passthrough: { bytes in
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { say("terminal: \(text.debugDescription.prefix(120))") }
        },
        makeWriter: { writer },
        requestSource: { $0(nil) },
        onState: { info in
            if let info, info.phase != .active {
                lock.withLock { state.finishedOK = info.phase == .done }
            } else if info == nil, writer.completed != nil {
                lock.withLock { state.finishedOK = writer.completed }
            }
        },
    )
    func hook(_ session: LabSession) {
        // One session per link; its id is not known until the open answers,
        // and sz speaks first.
        session.link.onEvent = { event in
            switch xpc_dictionary_get_uint64(event, iGhostVTWireKey.event) {
            case iGhostVTEvent.output.rawValue:
                if let bytes = data(iGhostVTWireKey.data, in: event) { engine.ingest(bytes) }
            case iGhostVTEvent.sessionExit.rawValue:
                session.exited(xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))
                say("sz exited with \(xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode))")
            default: break
            }
        }
    }
    let first = LabSession(link: connect(device))
    lock.withLock { state.current = first }
    hook(first)
    guard first.open([options["sz"] ?? "/opt/homebrew/bin/sz", path]) else { fail("openSession refused") }
    let sessionID = first.id
    let started = Date()
    var session = first
    for drop in 0 ..< drops {
        let at = size * UInt64(drop + 1) / UInt64(drops + 1)
        while writer.received < at, Date().timeIntervalSince(started) < 600, lock.withLock({ state.finishedOK }) == nil,
              session.waitForExit(timeout: 0) == nil
        {
            usleep(20000)
        }
        guard lock.withLock({ state.finishedOK }) == nil, session.waitForExit(timeout: 0) == nil else { break }
        say("drop \(drop): link gone at \(writer.received) bytes, back in \(outage) s")
        session.link.onEvent = nil
        session.link.frames.connection.forceCancel()
        let loss = engine.suspendForLostLink()
        verdict.check(loss == .suspended, "drop \(drop): the download was kept (\(loss))")
        Thread.sleep(forTimeInterval: outage)
        var next: LabSession?
        let retryStarted = Date()
        while next == nil, Date().timeIntervalSince(retryStarted) < 40 {
            if case let .success(link) = tryConnect(device, quiet: true) {
                let candidate = LabSession(link: link)
                if candidate.attach(sessionID) == .success {
                    next = candidate
                } else {
                    link.close()
                }
            }
            if next == nil { usleep(500_000) }
        }
        guard let next else {
            verdict.check(false, "drop \(drop): reattached")
            return verdict.finish()
        }
        lock.withLock { state.current = next }
        hook(next)
        engine.resume()
        session = next
    }
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline, lock.withLock({ state.finishedOK }) == nil {
        usleep(50000)
    }
    Thread.sleep(forTimeInterval: 1)
    verdict.check(lock.withLock({ state.finishedOK }) == true, "the transfer finished")
    verdict.check(writer.digest == expected && writer.received == size, "the file is whole (\(writer.received) of \(size) bytes, checksum \(writer.digest == expected ? "matches" : "differs"))")
    verdict.note(String(format: "%.1f s with %d drop(s) of %.0f s", Date().timeIntervalSince(started), drops, outage))
    if session.waitForExit(timeout: 0) == nil {
        session.close()
    }
    session.link.close()
    return verdict.finish()
}

func runScenario(_ name: String) -> Int32 {
    let size = Int(options["size"] ?? "") ?? 0
    switch name {
    case "trickle": return trickle(count: 20, interval: 2, limit: 6)
    case "idle": return trickle(count: 3, interval: 100, limit: 6)
    case "echo": return echo(count: 40)
    case "flood": return flood(seconds: 6)
    case "paste": return paste(byteCount: size > 0 ? size : 2 << 20)
    case "reattach": return reattach(cycles: 3)
    case "storm": return storm(count: size > 0 ? size : 10)
    case "upload": return upload(byteCount: size > 0 ? size : 4 << 20)
    case "sz-drops": return szAcrossDrops(megabytes: size > 0 ? size : 16, drops: 3, outage: 3)
    case "sz-long-drop": return szAcrossDrops(megabytes: size > 0 ? size : 16, drops: 1, outage: 15)
    default: fail("no scenario \(name)")
    }
}
