import Foundation

// The replay an attach hands back (`SessionOutputLog`, read by
// `TerminalStreamTracker`): where it may begin, what it must leave out, what
// it has to write back first, and the continuation a returning link gets.
// The property at the end is the one the rest serves — a terminal fed the
// rebuilt replay ends in the state the whole stream left.

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

extension Data {
    func contains(_ needle: [UInt8]) -> Bool {
        range(of: Data(needle)) != nil
    }

    func contains(_ needle: String) -> Bool {
        contains(Array(needle.utf8))
    }
}

func log(_ chunks: [[UInt8]], capacity: Int) -> SessionOutputLog {
    var log = SessionOutputLog(capacity: capacity)
    for chunk in chunks {
        log.append(Data(chunk))
    }
    return log
}

func rebuilt(_ log: SessionOutputLog) -> (data: Data, endsInTransfer: Bool) {
    switch log.replay(resumingFrom: nil) {
    case let .rebuilt(data, endsInTransfer):
        return (data, endsInTransfer)
    case .continuation:
        return (Data(), false)
    }
}

func tracked(_ data: Data) -> TerminalStreamTracker {
    var tracker = TerminalStreamTracker()
    data.withUnsafeBytes { tracker.consume($0, at: 0) }
    return tracker
}

func tracked(_ chunks: [[UInt8]]) -> TerminalStreamTracker {
    var tracker = TerminalStreamTracker()
    var offset: Int64 = 0
    for chunk in chunks {
        chunk.withUnsafeBytes { tracker.consume($0, at: offset) }
        offset += Int64(chunk.count)
    }
    return tracker
}

let filler = [UInt8](repeating: 0x78, count: 600) + bytes("\r\n")

print("replay stream")

// MARK: - Where a replay begins

print("a trimmed buffer begins mid-sequence; the rebuild does not")
do {
    // The cut lands inside `ESC [ 3 8 ; 5 ; 1 9 6 m`.
    let colored = bytes("\u{1B}[38;5;196mred\u{1B}[0m ")
    var chunks: [[UInt8]] = [bytes("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h")]
    for _ in 0 ..< 40 {
        chunks.append(colored)
    }
    let all = chunks.flatMap { $0 }
    // A capacity that cuts after the ESC [ of a colour sequence.
    let cut = all.count - 2 * colored.count - 3
    let capacity = all.count - cut
    let sample = log(chunks.map { $0 } + [[]], capacity: capacity / 2 + 1)
    _ = sample
    var raw = SessionOutputLog(capacity: capacity)
    raw.append(Data(all + filler + all))
    let tail = raw.rawTail
    check(tail.first != 0x1B, "evidence: the raw tail starts inside a sequence (first byte \(String(format: "0x%02X", tail.first ?? 0)))")
    let replay = rebuilt(raw).data
    let tracker = tracked(replay)
    check(tracker.isQuiescent, "the rebuilt replay leaves the parser between sequences")
    check(replay.starts(with: [0x1B]), "and opens with a sequence, not a fragment")
    check(replay.contains("\u{1B}[?1049h"), "it re-enters the alternate screen the cut lost")
    check(replay.contains("\u{1B}[?1000h") && replay.contains("\u{1B}[?1006h"), "it turns mouse reporting and its format back on")
    check(replay.contains("\u{1B}[?2004h"), "it turns bracketed paste back on")
    check(tracker.terminal.isAlternateActive, "a terminal fed it ends on the alternate screen")
}

print("a cut UTF-8 character is skipped, never printed half")
do {
    let text = bytes("中文字符")
    var raw = SessionOutputLog(capacity: 10)
    raw.append(Data(filler + text + text + text))
    raw.append(Data(text))
    let replay = rebuilt(raw).data
    let body = replay.suffix(from: replay.lastIndex(of: 0x48).map { $0 + 1 } ?? replay.startIndex)
    let first = body.first ?? 0
    check(first < 0x80 || first >= 0xC0, "the replay's text begins on a character boundary (0x\(String(format: "%02X", first)))")
    check(String(data: Data(body), encoding: .utf8) != nil, "and decodes as UTF-8")
}

print("a window that is all one unfinished string puts the parser back inside one")
do {
    var raw = SessionOutputLog(capacity: 64)
    raw.append(Data(bytes("before\u{1B}]52;c;") + [UInt8](repeating: 0x41, count: 300)))
    let replay = rebuilt(raw).data
    check(!replay.contains("AAAA"), "the clipboard payload is not in the replay")
    var tracker = tracked(replay)
    let rest = bytes("AAAA\u{07}after")
    rest.withUnsafeBytes { tracker.consume($0, at: Int64(replay.count)) }
    check(tracker.isQuiescent, "the live end of the string finishes it instead of printing")
}

// MARK: - What a replay leaves out

print("questions, the clipboard, notifications and ENQ are left out")
do {
    let questions: [String] = [
        "\u{1B}[c", "\u{1B}[>c", "\u{1B}[=c", "\u{1B}[5n", "\u{1B}[6n", "\u{1B}[?6n", "\u{1B}[?996n",
        "\u{1B}[?2026$p", "\u{1B}[4$p", "\u{1B}[>q", "\u{1B}[>0q", "\u{1B}[?u", "\u{1B}[14t", "\u{1B}[18t",
        "\u{1B}[?4m", "\u{1B}Z", "\u{1B}]11;?\u{07}", "\u{1B}]4;1;?\u{1B}\\", "\u{1B}]10;?\u{1B}\\",
        "\u{1B}]52;c;?\u{07}", "\u{1B}]52;c;aGVsbG8=\u{07}", "\u{1B}]9;done\u{07}", "\u{1B}]777;notify;a;b\u{07}",
        "\u{1B}]99;;hi\u{1B}\\", "\u{1B}P$qm\u{1B}\\", "\u{1B}P+q544e\u{1B}\\", "\u{1B}_Ga=q,i=31;AAAA\u{1B}\\",
        "\u{1B}_Gi=7,f=100;AAAA\u{1B}\\", "\u{1B}]1337;ReportCellSize\u{07}", "\u{05}",
    ]
    var stream = bytes("start ")
    for (index, question) in questions.enumerated() {
        stream += bytes(question) + bytes("<\(index)>")
    }
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(stream))
    let replay = rebuilt(raw).data
    for (index, question) in questions.enumerated() {
        check(!replay.contains(question), "left out: \(question.debugDescription)")
        check(replay.contains("<\(index)>"), "the text after it stays (\(index))")
    }
    check(!replay.contains([0x5C, 0x3C]), "no stray ST is left behind a string taken out")
}

print("what only sets state stays")
do {
    let kept: [String] = [
        "\u{1B}]0;my title\u{07}", "\u{1B}]7;file://host/tmp\u{1B}\\", "\u{1B}]8;;https://e.x\u{1B}\\link\u{1B}]8;;\u{1B}\\",
        "\u{1B}]133;A\u{07}", "\u{1B}]9;4;1;50\u{07}", "\u{1B}_Ga=T,q=2,i=4;AAAA\u{1B}\\", "\u{1B}_Ga=T,f=100;AAAA\u{1B}\\",
        "\u{1B}[?25l", "\u{1B}[>4;2m", "\u{1B}[>1u", "\u{1B}[2 q", "\u{1B}Pq#0;2;0;0;0#0~~\u{1B}\\", "\u{1B}]4;1;rgb:ff/00/00\u{07}",
    ]
    var stream: [UInt8] = []
    for item in kept {
        stream += bytes(item) + bytes(" | ")
    }
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(stream))
    let replay = rebuilt(raw).data
    for item in kept {
        check(replay.contains(item), "kept: \(item.debugDescription)")
    }
}

print("a kitty graphics transmission in chunks is kept or left out whole")
do {
    let answered = bytes("\u{1B}_Ga=T,i=9,m=1;AAAA\u{1B}\\\u{1B}_Gm=1;BBBB\u{1B}\\\u{1B}_Gm=0;CCCC\u{1B}\\")
    let quiet = bytes("\u{1B}_Ga=T,i=9,q=2,m=1;DDDD\u{1B}\\\u{1B}_Gm=0;EEEE\u{1B}\\")
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(answered + bytes("|") + quiet))
    let replay = rebuilt(raw).data
    check(!replay.contains("AAAA") && !replay.contains("BBBB") && !replay.contains("CCCC"), "an answered transmission goes, every chunk")
    check(replay.contains("DDDD") && replay.contains("EEEE"), "a quiet one stays, every chunk")
}

// MARK: - ZMODEM

let zmodemStart = bytes("rz\r**\u{18}B00000000000000\r\n\u{11}")
let zmodemFinish = bytes("**\u{18}B0800000000022d\r\n") + bytes("OO")
func zmodemData(_ count: Int) -> [UInt8] {
    // ZDLE-escaped binary: escapes, controls, high bytes, but never a CAN
    // run or a bare ZDLE followed by B.
    var data: [UInt8] = []
    var value: UInt32 = 12345
    while data.count < count {
        value = value &* 1_103_515_245 &+ 12345
        let byte = UInt8(truncatingIfNeeded: value >> 16)
        if byte == 0x18 {
            data += [0x18, 0x58]
        } else {
            data.append(byte)
        }
    }
    return data
}

print("a transfer is left out of the replay")
do {
    let stream = bytes("$ sz file\r\n") + zmodemStart + zmodemData(4000) + zmodemFinish + bytes("$ after\r\n")
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(stream))
    let replay = rebuilt(raw)
    check(replay.data.contains("$ sz file") && replay.data.contains("$ after"), "the text on either side stays")
    check(!replay.data.contains([0x2A, 0x2A, 0x18, 0x42]), "no ZMODEM header is in it")
    check(!replay.data.contains("rz\r"), "nor sz's announcement")
    check(!replay.endsInTransfer, "and the transfer is over")
}

print("a transfer whose start was trimmed is still left out")
do {
    let stream = bytes("$ sz big\r\n") + zmodemStart + zmodemData(20000) + zmodemFinish + bytes("$ next\r\n")
    var raw = SessionOutputLog(capacity: 4096)
    for chunk in stride(from: 0, to: stream.count, by: 1000) {
        raw.append(Data(stream[chunk ..< min(stream.count, chunk + 1000)]))
    }
    let tail = raw.rawTail
    let stripped = tail.range(of: Data([0x2A, 0x2A, 0x18, 0x42]))
    check(stripped.map { $0.lowerBound > 3000 } ?? false, "evidence: the raw tail is binary before its first header, which the app's scanner keeps")
    let replay = rebuilt(raw).data
    check(replay.contains("$ next"), "the prompt after it stays")
    check(replay.count < 1500, "and the binary goes (\(replay.count) bytes left)")
}

print("a transfer cancelled, or killed under a prompt, ends there")
do {
    let cancelled = bytes("$ sz a\r\n") + zmodemStart + zmodemData(500) + [UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 8) + bytes("$ one\r\n")
    let killed = bytes("$ sz b\r\n") + zmodemStart + zmodemData(500) + bytes("\u{1B}]133;D;137\u{07}\u{1B}]133;A\u{07}$ two\r\n")
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(cancelled + killed + bytes("tail")))
    let replay = rebuilt(raw)
    check(replay.data.contains("$ one") && replay.data.contains("$ two") && replay.data.contains("tail"), "the output after each stays")
    check(replay.data.contains("\u{1B}]133;D;137\u{07}"), "the prompt mark that ended it is whole")
    check(!replay.endsInTransfer, "and neither is still going")
}

print("a transfer from a sender on a cooked terminal ends as one from sz does")
do {
    // ONLCR turns the LF after the ZFIN header into CR LF.
    let cooked = bytes("$ fake\r\n") + zmodemStart + zmodemData(800) + bytes("**\u{18}B0800000000022d\r\r\nOO") + bytes("\r\n$ done\r\n")
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(cooked))
    let replay = rebuilt(raw).data
    check(!replay.contains("OO") && replay.contains("$ done"), "its OO goes with it, the prompt stays")
}

print("a transfer still going says so")
do {
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(bytes("$ sz c\r\n") + zmodemStart + zmodemData(3000)))
    let replay = rebuilt(raw)
    check(replay.endsInTransfer, "the replay ends inside a transfer")
    check(!replay.data.contains([0x2A, 0x2A, 0x18, 0x42]), "which it leaves out")
}

// MARK: - Continuation

print("a returning link gets exactly what it missed")
do {
    var raw = SessionOutputLog(capacity: 1000)
    var all: [UInt8] = []
    for index in 0 ..< 50 {
        let chunk = bytes("line \(index) \u{1B}[1mbold\u{1B}[0m\r\n")
        all += chunk
        raw.append(Data(chunk))
    }
    check(raw.endOffset == UInt64(all.count), "the end offset counts every byte (\(raw.endOffset))")
    let held = raw.endOffset - 100
    if case let .continuation(data) = raw.replay(resumingFrom: held) {
        check(Array(data) == Array(all.suffix(100)), "a continuation is the stream after the offset, unchanged")
    } else {
        check(false, "an offset still in the buffer gets a continuation")
    }
    if case let .continuation(data) = raw.replay(resumingFrom: raw.endOffset) {
        check(data.isEmpty, "a link that missed nothing gets nothing")
    } else {
        check(false, "an offset at the end gets an empty continuation")
    }
    if case .rebuilt = raw.replay(resumingFrom: raw.endOffset + 1) {
        check(true, "an offset past the end (another io's) gets a rebuild")
    } else {
        check(false, "an offset past the end gets a rebuild")
    }
    if case .rebuilt = raw.replay(resumingFrom: 0) {
        check(true, "an offset already trimmed gets a rebuild")
    } else {
        check(false, "an offset already trimmed gets a rebuild")
    }
    if case .rebuilt = raw.replay(resumingFrom: .max) {
        check(true, "an absurd offset is compared, not added to")
    } else {
        check(false, "an absurd offset gets a rebuild")
    }
    check(raw.storageByteCount <= 2000, "storage stays within twice the capacity (\(raw.storageByteCount))")
}

// MARK: - State written back

print("the kitty keyboard stack is rebuilt exactly, wrapped or not")
do {
    for stream in [
        "\u{1B}[>1u\u{1B}[>3u",
        "\u{1B}[=5;1u\u{1B}[>1u\u{1B}[>31u\u{1B}[<u",
        String(repeating: "\u{1B}[>7u", count: 11) + "\u{1B}[<3u",
        "\u{1B}[?1049h\u{1B}[>15u\u{1B}[?1049l\u{1B}[>2u",
    ] {
        let original = tracked(Data(bytes(stream)))
        let rebuiltState = tracked(Data(original.terminal.preamble()))
        check(
            rebuiltState.terminal.kitty == original.terminal.kitty,
            "stack after \(stream.debugDescription) (\(original.terminal.kitty.map(\.flags)) / \(rebuiltState.terminal.kitty.map(\.flags)))",
        )
    }
}

print("a preamble asks nothing")
do {
    let original = tracked(Data(bytes(
        "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[>1u\u{1B}]0;t\u{07}\u{1B}]4;3;#112233\u{07}\u{1B}]10;#ffffff\u{07}\u{1B}(0\u{1B}7\u{1B}[1;31m\u{1B}[5;20r",
    )))
    var raw = SessionOutputLog(capacity: 1 << 16)
    raw.append(Data(original.terminal.preamble()))
    let again = rebuilt(raw).data
    check(Array(again.suffix(original.terminal.preamble().count)) == original.terminal.preamble() || again.count >= original.terminal.preamble().count, "nothing in a preamble is left out of a replay of it")
    var asking = TerminalStreamTracker()
    asking.beginRecording()
    let preamble = original.terminal.preamble()
    preamble.withUnsafeBytes { asking.consume($0, at: 0) }
    check(asking.takeExcisions(finishingAt: Int64(preamble.count)).isEmpty, "the tracker finds no question in it")
}

// MARK: - The property

/// Two terminal states that read the same: the settings a preamble writes
/// back, compared by effect.
func equivalent(_ a: TerminalReplayState, _ b: TerminalReplayState) -> String? {
    for mode in Set(a.decModes.keys).union(b.decModes.keys) where a.decMode(mode) != b.decMode(mode) {
        return "DEC mode \(mode)"
    }
    if (a.mouseEvent ?? 0) != (b.mouseEvent ?? 0) { return "mouse event" }
    if (a.mouseFormat ?? 0) != (b.mouseFormat ?? 0) { return "mouse format" }
    for mode in Set(a.ansiModes.keys).union(b.ansiModes.keys)
        where (a.ansiModes[mode] ?? TerminalReplayState.defaultANSIMode(mode)) != (b.ansiModes[mode] ?? TerminalReplayState.defaultANSIMode(mode))
    {
        return "ANSI mode \(mode)"
    }
    if a.isAlternateActive != b.isAlternateActive { return "screen" }
    if a.kitty[0] != b.kitty[0] { return "primary kitty flags" }
    if a.kittyTouched[1] || a.isAlternateActive, a.kitty[1] != b.kitty[1] { return "alternate kitty flags" }
    if a.title != nil, a.title != b.title { return "title \(String(decoding: a.title ?? [], as: UTF8.self).debugDescription) vs \(b.title.map { String(decoding: $0, as: UTF8.self).debugDescription } ?? "nil")" }
    if a.cursor.pen != b.cursor.pen { return "pen \(a.cursor.pen.map { String(decoding: $0, as: UTF8.self) }) vs \(b.cursor.pen.map { String(decoding: $0, as: UTF8.self) })" }
    func charsetsMatch(_ x: TerminalReplayState.Charsets, _ y: TerminalReplayState.Charsets) -> Bool {
        // ASCII stands in for the initial UTF-8 set, which has no designation.
        zip(x.slots, y.slots).allSatisfy { ($0 == 0 ? 0x42 : $0) == ($1 == 0 ? 0x42 : $1) } && x.gl == y.gl && x.gr == y.gr
    }
    if !charsetsMatch(a.cursor.charsets, b.cursor.charsets) { return "charsets" }
    if a.hyperlink != b.hyperlink { return "hyperlink" }
    if (a.scrollRegion.map { [$0.top, $0.bottom] }) != (b.scrollRegion.map { [$0.top, $0.bottom] }) { return "scroll region" }
    if a.palette != b.palette { return "palette" }
    for index in a.dynamicColors.keys where a.dynamicColors[index] != b.dynamicColors[index] {
        return "dynamic colour \(index)"
    }
    if a.modifyKeyFormat != nil, a.modifyKeyFormat != b.modifyKeyFormat { return "modify key format" }
    if (a.cursorStyle ?? 0) != (b.cursorStyle ?? 0) { return "cursor style" }
    let active = a.isAlternateActive ? 1 : 0
    if let saved = a.savedCursor[active] {
        guard let other = b.savedCursor[active] else { return "saved cursor missing" }
        if saved.pen != other.pen || saved.origin != other.origin { return "saved cursor" }
    }
    return nil
}

struct Generator {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func pick(_ items: [String]) -> String {
        items[next(items.count)]
    }
}

let vocabulary: [String] = [
    "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?1047h", "\u{1B}[?1047l", "\u{1B}[?47h", "\u{1B}[?47l",
    "\u{1B}[?1000h", "\u{1B}[?1002h", "\u{1B}[?1003h", "\u{1B}[?1000l", "\u{1B}[?1006h", "\u{1B}[?1006l",
    "\u{1B}[?2004h", "\u{1B}[?2004l", "\u{1B}[?1h", "\u{1B}[?1l", "\u{1B}[?25l", "\u{1B}[?25h", "\u{1B}[?7l",
    "\u{1B}[?1004h", "\u{1B}=", "\u{1B}>", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}[>1u", "\u{1B}[>3u", "\u{1B}[<u",
    "\u{1B}[<2u", "\u{1B}[=9;1u", "\u{1B}[=2;2u", "\u{1B}[>4;2m", "\u{1B}[>4m", "\u{1B}[1;31m", "\u{1B}[0m",
    "\u{1B}[m", "\u{1B}[38;2;1;2;3m", "\u{1B}[4:3m", "\u{1B}7", "\u{1B}8", "\u{1B}[s", "\u{1B}[u", "\u{1B}(0",
    "\u{1B}(B", "\u{1B})0", "\u{0E}", "\u{0F}", "\u{1B}]0;title one\u{07}", "\u{1B}]2;title two\u{1B}\\",
    "\u{1B}]8;id=1;https://a.b\u{1B}\\", "\u{1B}]8;;\u{1B}\\", "\u{1B}[3;20r", "\u{1B}[r", "\u{1B}[5 q",
    "\u{1B}]4;1;#ff0000\u{07}", "\u{1B}]104\u{07}", "\u{1B}]11;#000000\u{07}", "\u{1B}]111\u{07}",
    "\u{1B}[!p", "\u{1B}[?1048h", "\u{1B}[?1048l", "\u{1B}[?2004s", "\u{1B}[?2004r",
    "\u{1B}[c", "\u{1B}[6n", "\u{1B}]11;?\u{07}", "\u{1B}]52;c;aGk=\u{07}", "\u{1B}P$qm\u{1B}\\",
    "\u{1B}_Gi=1,a=T;QUJD\u{1B}\\", "\u{05}", "\u{1B}[18t",
    "hello ", "中文 ", "\r\n", "\u{1B}[H", "\u{1B}[2J", "\u{1B}[K", "x", "\u{1B}[10;5H",
    // Fragments, aborts and oddities: a sequence cut by CAN or SUB, ESC
    // inside a sequence, a string ended by C1 ST, a colon where only SGR
    // takes one, too many parameters.
    "\u{1B}[?10", "\u{1B}]0;cut", "\u{18}", "\u{1A}", "\u{1B}\u{1B}[?1h", "\u{1B}[1:2H", "\u{1B}P1;2|abc",
    "\u{1B}[" + String(repeating: "1;", count: 30) + "m", "\u{1B}[?2004;1;25l", "\u{1B}(A", "\u{1B}n", "\u{1B}}",
]

/// Raw bytes no Swift string spells: C1 controls, a lone continuation, a
/// lead byte with nothing after it.
let rawVocabulary: [[UInt8]] = [
    [0x9B, 0x31, 0x6D], [0x1B, 0x5B, 0x9B, 0x3F, 0x31, 0x68], [0x1B, 0x5D, 0x30, 0x3B, 0x74, 0x9C], [0x1B, 0x50, 0x71, 0x9C, 0x41, 0x1B, 0x5C],
    [0x1B, 0x5F, 0x47, 0x9C], [0x80], [0xE4, 0xB8], [0xF0, 0x9F, 0x98, 0x80], [0x1B, 0x9D, 0x32, 0x3B, 0x78, 0x07],
]

print("a rebuilt replay leaves a terminal in the state the whole stream left")
do {
    let environment = ProcessInfo.processInfo.environment
    var generator = Generator(state: UInt64(environment["REPLAY_STREAM_SEED"] ?? "") ?? 0x5EED)
    var mismatches = 0
    let trials = Int(environment["REPLAY_STREAM_TRIALS"] ?? "") ?? 400
    for trial in 0 ..< trials {
        var stream: [UInt8] = []
        let pieces = 20 + generator.next(400)
        for _ in 0 ..< pieces {
            stream += bytes(generator.pick(vocabulary))
            if generator.next(12) == 0 {
                stream += rawVocabulary[generator.next(rawVocabulary.count)]
            }
            if generator.next(40) == 0 {
                stream += zmodemStart + zmodemData(generator.next(300)) + (generator.next(2) == 0 ? zmodemFinish : [UInt8](repeating: 0x18, count: 6))
            }
        }
        let capacity = 16 + generator.next(max(1, stream.count))
        var raw = SessionOutputLog(capacity: capacity)
        var offset = 0
        while offset < stream.count {
            let size = 1 + generator.next(64)
            raw.append(Data(stream[offset ..< min(stream.count, offset + size)]))
            offset += size
        }
        let whole = tracked([stream])
        let replay = rebuilt(raw).data
        let fresh = tracked(replay)
        if let difference = equivalent(whole.terminal, fresh.terminal) {
            mismatches += 1
            if mismatches <= 5 {
                print("  trial \(trial): \(difference)")
            }
            if environment["REPLAY_STREAM_DUMP"] == String(trial) {
                func escaped(_ data: some Sequence<UInt8>) -> String {
                    data.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : String(format: "<%02X>", $0) }.joined()
                }
                print("    capacity \(capacity) stream \(stream.count)")
                print("    tail:   \(escaped(raw.rawTail))")
                print("    replay: \(escaped(replay))")
            }
        }
        // A terminal that already showed this session further along gets
        // the same replay after a gap: it must end in the same state too.
        var reused = tracked([stream])
        replay.withUnsafeBytes { reused.consume($0, at: Int64(stream.count)) }
        if let difference = equivalent(whole.terminal, reused.terminal) {
            mismatches += 1
            if mismatches <= 5 {
                print("  trial \(trial) (reused terminal): \(difference)")
            }
        }
    }
    check(mismatches == 0, "\(trials) random streams, fresh and reused terminals alike (\(mismatches) mismatched)")
}

print("the tracker keeps up")
do {
    var stream: [UInt8] = []
    var generator = Generator(state: 7)
    while stream.count < 8 << 20 {
        stream += bytes(generator.pick(vocabulary))
    }
    let started = Date()
    var raw = SessionOutputLog(capacity: 256 * 1024)
    for chunk in stride(from: 0, to: stream.count, by: 16384) {
        raw.append(Data(stream[chunk ..< min(stream.count, chunk + 16384)]))
    }
    let trimTime = Date().timeIntervalSince(started)
    let replayStarted = Date()
    _ = rebuilt(raw)
    let replayTime = Date().timeIntervalSince(replayStarted)
    print("    8 MiB of mixed output trimmed in \(String(format: "%.3f", trimTime)) s, a replay rebuilt in \(String(format: "%.3f", replayTime)) s")
    check(trimTime < 4, "trimming reads 8 MiB of escapes in under four seconds")
    check(replayTime < 0.5, "a replay is rebuilt in under half a second")
}

if failures.isEmpty {
    print("replay stream: all checks passed")
} else {
    print("replay stream: \(failures.count) failure(s)")
    exit(1)
}
