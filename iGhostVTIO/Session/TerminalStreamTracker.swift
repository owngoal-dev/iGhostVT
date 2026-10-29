/// Reads a session's output the way Ghostty reads it, for the replay an
/// attach hands back.
///
/// The replay buffer is raw output trimmed from the front, and a terminal
/// fed it as it is starts reading mid-session: a cut escape sequence prints
/// its parameters as text, a cut character prints U+FFFD, and whatever the
/// program set before the cut — the alternate screen, mouse reporting,
/// bracketed paste, the kitty keyboard flags — is not there, so a program
/// still running is sent input the terminal no longer encodes the way it
/// asked. Worse, the replay is history played again: a query in it is
/// answered again, into the program's input, and a clipboard write or a
/// notification happens again. A ZMODEM transfer in it is a screen of
/// binary.
///
/// The tracker reads every byte once, as the buffer is trimmed, keeping
/// the state the output leaves (`terminal`) and the parser's own position,
/// so a replay can begin where Ghostty is between sequences, open with that
/// state written back, and leave out what must not happen twice
/// (`beginRecording`, `takeExcisions`).
///
/// The parser is Ghostty's at the commit libghostty-spm pins: the state
/// table of `Parser.zig`, the UTF-8 handling of `stream.zig` (bytes are
/// decoded in the ground state, where C1 bytes are not controls), the
/// parameter rules (24 at most, colons only for SGR), the OSC, DCS and APC
/// terminators. A sequence has to end here exactly where it ends there, or
/// the replay would begin inside one Ghostty is still reading.
struct TerminalStreamTracker {
    private(set) var terminal = TerminalReplayState()

    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case oscString
        case apcString
    }

    private enum StringEnd {
        /// BEL, ST (C1), or the ESC that begins `ESC \`.
        case terminated
        /// CAN or SUB.
        case cancelled
    }

    /// Where a ZMODEM conversation is: the data, a run of CAN that may be
    /// the sender's cancel, or the ZFIN header and what follows it.
    private enum ZmodemPhase: Equatable {
        case idle
        case data(cancels: Int)
        case afterCancel
        case finishHex
        case finishTrailer
        case finishFirstO
    }

    private enum KittyChain {
        case none
        case keep
        case excise
    }

    private static let maximumParams = 24
    private static let maximumIntermediates = 4
    private static let maximumHead = 64
    /// The OSC, DCS or APC payload kept for reading it: enough for any
    /// title, colour or link Ghostty keeps without allocating, and for the
    /// control keys of a kitty graphics command.
    private static let maximumPayload = 4096

    private var state = ParserState.ground
    private var utf8Remaining = 0
    private var utf8Lower: UInt8 = 0x80
    private var utf8Upper: UInt8 = 0xBF

    /// Where the sequence being read began — its ESC or C1 introducer — in
    /// stream offsets.
    private var sequenceStart: Int64 = 0
    private var intermediates: [UInt8] = []
    private var params: [UInt16] = []
    /// Bit `i`: a colon, not a semicolon, followed parameter `i`.
    private var colons: UInt32 = 0
    private var paramValue: UInt16 = 0
    private var paramDigits = 0
    private var paramsOverflowed = false
    /// The bytes of the ESC or CSI being read, for a replay that ends inside
    /// one begun before it.
    private var head: [UInt8] = []
    private var payload: [UInt8] = []
    private var payloadOverflowed = false
    private var dcsFinal: UInt8 = 0
    private var dcsIntermediates: [UInt8] = []
    /// A string just left out ended at an ESC: the `\` after it is the
    /// rest of its ST, and goes with it.
    private var terminatorPending = false

    /// The last eight bytes, for the ZMODEM headers.
    private var recent: UInt64 = 0
    private var zmodem = ZmodemPhase.idle
    private var zmodemStart: Int64 = 0
    /// Progress through `ESC ] 1 3 3 ;` and a prompt mark, inside a
    /// conversation: a shell drawing its prompt again is a transfer that
    /// ended without a word (sz killed).
    private var promptMarkProgress = 0

    private var kittyChain = KittyChain.none

    /// A stretch a replay leaves out, and what stands in its place. A
    /// sequence's introducer also ends whatever it interrupted, and taken
    /// out alone it would leave that running on into what follows: a
    /// string the replay keeps (Ghostty ends it at the ESC, as ST does), an
    /// unfinished CSI or ESC, or a half-read character (both of which CAN
    /// abandons, as the ESC did).
    struct Excision {
        var range: Range<Int64>
        var replacement: [UInt8] = []
    }

    private var excisions: [Excision]?
    /// What stands in for the sequence being read if it is left out: what
    /// its introducer ended (`Excision`).
    private var sequenceStandIn: [UInt8] = []

    init() {}

    /// Between sequences, between characters, and outside a transfer: the
    /// point a replay can begin at.
    var isQuiescent: Bool {
        state == .ground && utf8Remaining == 0 && zmodem == .idle
    }

    var isInZmodemConversation: Bool {
        zmodem != .idle
    }

    // MARK: - Recording

    /// Records, from here on, the stretches a replay leaves out. A kitty
    /// graphics transmission begun before this point continues without the
    /// command that started it, and is left out to its last chunk.
    mutating func beginRecording() {
        excisions = []
        if kittyChain != .none {
            kittyChain = .excise
        }
    }

    /// What was recorded, with a conversation still going at `end` left
    /// out up to there; recording stops.
    mutating func takeExcisions(finishingAt end: Int64) -> [Excision] {
        if zmodem != .idle {
            exciseConversation(to: end)
        }
        let taken = excisions ?? []
        excisions = nil
        return taken
    }

    /// Never builds a `Range` from bounds out of order: that traps, and a
    /// trap here ends every shell `ighostvtd-io` holds.
    private mutating func excise(from lower: Int64, to upper: Int64) {
        guard excisions != nil, lower < upper else { return }
        excisions?.append(Excision(range: lower ..< upper, replacement: lower == sequenceStart ? sequenceStandIn : []))
    }

    /// What puts Ghostty's parser where this one is, for a replay that ends
    /// before the sequence it is in does: the live bytes that follow then
    /// finish it there instead of printing. An ESC or CSI is written as it
    /// began; a string becomes one Ghostty ignores, so the rest of a
    /// clipboard write or an image is read and dropped rather than shown
    /// or acted on with half its payload.
    var continuationPrefix: [UInt8] {
        switch state {
        case .ground:
            return []
        case .escape, .escapeIntermediate, .csiEntry, .csiParam, .csiIntermediate:
            return head.count < Self.maximumHead ? head : [0x1B, 0x5B, 0x3A]
        case .csiIgnore:
            return [0x1B, 0x5B, 0x3A]
        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore:
            return [0x1B, 0x50, 0x3A]
        case .oscString:
            return [0x1B, 0x5D, 0x3B]
        case .apcString:
            return [0x1B, 0x5F, 0x20]
        }
    }

    // MARK: - Reading

    mutating func consume(_ bytes: UnsafeRawBufferPointer, at base: Int64) {
        let count = bytes.count
        var index = 0
        while index < count {
            // The byte after a CAN may complete a ZMODEM header, so it
            // takes the slow path.
            if zmodem == .idle, state == .ground, utf8Remaining == 0, recent & 0xFF != 0x18 {
                // Text and the controls that change nothing kept here run
                // straight through: they are nearly all of any output.
                var end = index
                while end < count {
                    let byte = bytes[end]
                    if byte >= 0x20, byte < 0x7F {
                        end += 1
                    } else if byte < 0x20, byte != 0x05, byte != 0x0E, byte != 0x0F, byte != 0x18, byte != 0x1B {
                        end += 1
                    } else {
                        break
                    }
                }
                if end > index {
                    for position in max(index, end - 8) ..< end {
                        recent = (recent << 8) | UInt64(bytes[position])
                    }
                    index = end
                    if index == count {
                        break
                    }
                }
            }
            step(bytes[index], at: base + Int64(index))
            index += 1
        }
    }

    private mutating func step(_ byte: UInt8, at offset: Int64) {
        recent = (recent << 8) | UInt64(byte)
        if zmodem != .idle {
            stepZmodem(byte, at: offset)
            return
        }
        // `**` ZDLE `B`: a hex header, the start of every conversation —
        // with sz's "rz\r" before it when sz is the one starting it.
        if recent & 0xFFFF_FFFF == 0x2A2A_1842 {
            var start = offset - 3
            if (recent >> 32) & 0xFF_FFFF == 0x72_7A0D {
                start = offset - 6
            }
            beginZmodem(at: start)
            return
        }
        if state == .ground {
            ground(byte, at: offset)
        } else {
            sequence(byte, at: offset)
        }
    }

    // MARK: - Ground

    private mutating func ground(_ byte: UInt8, at offset: Int64) {
        let interruptsCharacter = utf8Remaining > 0
        if utf8Remaining > 0 {
            if byte >= utf8Lower, byte <= utf8Upper {
                utf8Remaining -= 1
                utf8Lower = 0x80
                utf8Upper = 0xBF
                return
            }
            // Not a continuation: Ghostty prints U+FFFD and reads the byte
            // again from the start.
            utf8Remaining = 0
            utf8Lower = 0x80
            utf8Upper = 0xBF
        }
        switch byte {
        case 0x1B:
            enter(.escape, at: offset)
            sequenceStandIn = interruptsCharacter ? [0x18] : []
        case 0x05 where interruptsCharacter:
            // ENQ: Ghostty answers it. The half-read character before it
            // still needs ending.
            if excisions != nil {
                excisions?.append(Excision(range: offset ..< offset + 1, replacement: [0x18]))
            }
        case 0x00 ... 0x1F:
            execute(byte, at: offset)
        case 0x20 ... 0x7F:
            break
        case 0xC2 ... 0xDF:
            utf8Remaining = 1
        case 0xE0:
            utf8Remaining = 2
            utf8Lower = 0xA0
        case 0xE1 ... 0xEC, 0xEE, 0xEF:
            utf8Remaining = 2
        case 0xED:
            utf8Remaining = 2
            utf8Upper = 0x9F
        case 0xF0:
            utf8Remaining = 3
            utf8Lower = 0x90
        case 0xF1 ... 0xF3:
            utf8Remaining = 3
        case 0xF4:
            utf8Remaining = 3
            utf8Upper = 0x8F
        default:
            break
        }
    }

    /// A C0 control Ghostty executes, in the ground state or inside a
    /// sequence.
    private mutating func execute(_ byte: UInt8, at offset: Int64) {
        switch byte {
        case 0x05:
            // ENQ: Ghostty answers it.
            excise(from: offset, to: offset + 1)
        case 0x0E:
            terminal.invokeCharset(gl: 1)
        case 0x0F:
            terminal.invokeCharset(gl: 0)
        default:
            break
        }
    }

    // MARK: - Sequences

    /// The transitions every state shares (`parse_table.zig`'s "anywhere"
    /// rows), for the bytes a state does not claim for itself. False when
    /// the byte is not one of them, and the state stays.
    private mutating func anywhere(_ byte: UInt8, at offset: Int64) -> Bool {
        switch byte {
        case 0x18, 0x1A:
            leave(to: .ground, end: .cancelled, at: offset)
        case 0x80 ... 0x8F, 0x91 ... 0x97, 0x99, 0x9A:
            leave(to: .ground, end: .cancelled, at: offset)
        case 0x9C:
            leave(to: .ground, end: .terminated, at: offset)
        case 0x1B:
            leave(to: .escape, end: .terminated, at: offset)
        case 0x98, 0x9E, 0x9F:
            leave(to: .apcString, end: .cancelled, at: offset)
        case 0x9B:
            leave(to: .csiEntry, end: .cancelled, at: offset)
        case 0x90:
            leave(to: .dcsEntry, end: .cancelled, at: offset)
        case 0x9D:
            leave(to: .oscString, end: .cancelled, at: offset)
        default:
            return false
        }
        return true
    }

    private static func isExecutedInSequence(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (byte >= 0x1C && byte <= 0x1F)
    }

    private mutating func sequence(_ byte: UInt8, at offset: Int64) {
        // No state claims CAN, SUB or ESC for itself.
        if byte == 0x18 || byte == 0x1A || byte == 0x1B {
            _ = anywhere(byte, at: offset)
            return
        }
        if head.count < Self.maximumHead {
            head.append(byte)
        }
        switch state {
        case .ground:
            ground(byte, at: offset)
        case .escape:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte == 0x7F {
                break
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
                state = .escapeIntermediate
            } else if byte == 0x5B {
                state = .csiEntry
            } else if byte == 0x5D {
                enterString(.oscString)
            } else if byte == 0x50 {
                state = .dcsEntry
            } else if byte == 0x58 || byte == 0x5E || byte == 0x5F {
                enterString(.apcString)
            } else if byte >= 0x30, byte <= 0x7E {
                state = .ground
                escapeDispatch(final: byte, at: offset)
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .escapeIntermediate:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
            } else if byte == 0x7F {
                break
            } else if byte >= 0x30, byte <= 0x7E {
                state = .ground
                escapeDispatch(final: byte, at: offset)
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .csiEntry:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte == 0x7F {
                break
            } else if byte >= 0x40, byte <= 0x7E {
                state = .ground
                csiDispatch(final: byte, at: offset)
            } else if byte == 0x3A {
                state = .csiIgnore
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
                state = .csiIntermediate
            } else if (byte >= 0x30 && byte <= 0x39) || byte == 0x3B {
                param(byte)
                state = .csiParam
            } else if byte >= 0x3C, byte <= 0x3F {
                collect(byte)
                state = .csiParam
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .csiParam:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte >= 0x30, byte <= 0x3B {
                param(byte)
            } else if byte == 0x7F {
                break
            } else if byte >= 0x40, byte <= 0x7E {
                state = .ground
                csiDispatch(final: byte, at: offset)
            } else if byte >= 0x3C, byte <= 0x3F {
                state = .csiIgnore
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
                state = .csiIntermediate
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .csiIntermediate:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
            } else if byte == 0x7F {
                break
            } else if byte >= 0x40, byte <= 0x7E {
                state = .ground
                csiDispatch(final: byte, at: offset)
            } else if byte >= 0x30, byte <= 0x3F {
                state = .csiIgnore
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .csiIgnore:
            if Self.isExecutedInSequence(byte) {
                execute(byte, at: offset)
            } else if byte >= 0x40, byte <= 0x7E {
                state = .ground
            } else if byte >= 0x80 {
                _ = anywhere(byte, at: offset)
            }
        case .dcsEntry:
            if Self.isExecutedInSequence(byte) || byte == 0x7F {
                break
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
                state = .dcsIntermediate
            } else if byte == 0x3A {
                state = .dcsIgnore
            } else if (byte >= 0x30 && byte <= 0x39) || byte == 0x3B {
                param(byte)
                state = .dcsParam
            } else if byte >= 0x3C, byte <= 0x3F {
                collect(byte)
                state = .dcsParam
            } else if byte >= 0x40, byte <= 0x7E {
                hookDCS(final: byte)
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .dcsParam:
            if Self.isExecutedInSequence(byte) || byte == 0x7F {
                break
            } else if (byte >= 0x30 && byte <= 0x39) || byte == 0x3B {
                param(byte)
            } else if byte == 0x3A || (byte >= 0x3C && byte <= 0x3F) {
                state = .dcsIgnore
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
                state = .dcsIntermediate
            } else if byte >= 0x40, byte <= 0x7E {
                hookDCS(final: byte)
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .dcsIntermediate:
            if Self.isExecutedInSequence(byte) || byte == 0x7F {
                break
            } else if byte >= 0x20, byte <= 0x2F {
                collect(byte)
            } else if byte >= 0x30, byte <= 0x3F {
                state = .dcsIgnore
            } else if byte >= 0x40, byte <= 0x7E {
                hookDCS(final: byte)
            } else {
                _ = anywhere(byte, at: offset)
            }
        case .dcsPassthrough, .dcsIgnore:
            // Everything but CAN, SUB and ESC belongs to the string, C1
            // bytes included.
            break
        case .oscString:
            if byte == 0x07 {
                leave(to: .ground, end: .terminated, at: offset)
            } else if byte >= 0x20 {
                appendPayload(byte)
            }
        case .apcString:
            if byte < 0x80 {
                appendPayload(byte)
            } else if byte <= 0x9F {
                _ = anywhere(byte, at: offset)
            }
        }
    }

    /// ESC from the ground state.
    private mutating func enter(_ newState: ParserState, at offset: Int64) {
        terminatorPending = false
        sequenceStandIn = []
        state = newState
        sequenceStart = offset
        clear()
        head = [0x1B]
    }

    /// Leaves the state through one of the transitions every state shares:
    /// the string being read ends (or is cancelled) here, and the next
    /// sequence, if any, begins at this byte.
    private mutating func leave(to newState: ParserState, end: StringEnd, at offset: Int64) {
        terminatorPending = false
        let leftOut = switch state {
        case .oscString: finishOSC(end: end)
        case .dcsPassthrough: finishDCS()
        case .apcString: finishAPC(end: end)
        default: false
        }
        let wasString = state == .oscString || state == .dcsPassthrough || state == .dcsIgnore || state == .apcString
        if leftOut {
            // An ESC is the start of `ESC \`, and its `\` goes too.
            let endsAtEscape = newState == .escape
            excise(from: sequenceStart, to: endsAtEscape ? offset : offset + 1)
            terminatorPending = endsAtEscape
        }
        if wasString {
            sequenceStandIn = leftOut ? [] : [0x1B, 0x5C]
        } else {
            sequenceStandIn = state == .ground ? [] : [0x18]
        }
        state = newState
        guard newState != .ground else { return }
        sequenceStart = offset
        clear()
        switch newState {
        case .csiEntry:
            head = [0x1B, 0x5B]
        case .oscString, .apcString:
            head = [0x1B]
            enterString(newState)
        default:
            head = [0x1B]
        }
    }

    private mutating func enterString(_ newState: ParserState) {
        state = newState
        payload.removeAll(keepingCapacity: true)
        payloadOverflowed = false
    }

    private mutating func clear() {
        intermediates.removeAll(keepingCapacity: true)
        params.removeAll(keepingCapacity: true)
        colons = 0
        paramValue = 0
        paramDigits = 0
        paramsOverflowed = false
    }

    private mutating func collect(_ byte: UInt8) {
        if intermediates.count < Self.maximumIntermediates {
            intermediates.append(byte)
        }
    }

    private mutating func param(_ byte: UInt8) {
        if byte == 0x3B || byte == 0x3A {
            guard params.count < Self.maximumParams else {
                paramsOverflowed = true
                return
            }
            if byte == 0x3A {
                colons |= 1 << UInt32(params.count)
            }
            params.append(paramValue)
            paramValue = 0
            paramDigits = 0
            return
        }
        // Saturating, as Ghostty's `*|=` and `+|=` are.
        let digit = UInt16(byte - 0x30)
        let (times, overflowed) = paramValue.multipliedReportingOverflow(by: 10)
        let (sum, carried) = times.addingReportingOverflow(digit)
        paramValue = (overflowed || carried) ? .max : sum
        paramDigits += 1
    }

    private mutating func appendPayload(_ byte: UInt8) {
        if payload.count < Self.maximumPayload {
            payload.append(byte)
        } else {
            payloadOverflowed = true
        }
    }

    private mutating func hookDCS(final: UInt8) {
        dcsFinal = final
        dcsIntermediates = intermediates
        state = .dcsPassthrough
    }

    // MARK: - ESC

    private mutating func escapeDispatch(final: UInt8, at offset: Int64) {
        if final == 0x5C, intermediates.isEmpty {
            // ST. The rest of a string left out goes with it.
            if terminatorPending, var last = excisions?.popLast() {
                last.range = last.range.lowerBound ..< max(last.range.upperBound, offset + 1)
                excisions?.append(last)
            }
            terminatorPending = false
            return
        }
        terminatorPending = false
        if intermediates.count == 1 {
            let slot: Int? = switch intermediates[0] {
            case 0x28: 0
            case 0x29: 1
            case 0x2A: 2
            case 0x2B: 3
            default: nil
            }
            if let slot, final == 0x42 || final == 0x41 || final == 0x30 {
                terminal.designateCharset(slot: slot, final: final)
            }
            return
        }
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x37: terminal.saveCursor() // 7
        case 0x38: terminal.restoreCursor() // 8
        case 0x3D: terminal.setDECMode(66, true) // = (DECKPAM is mode 66 in Ghostty)
        case 0x3E: terminal.setDECMode(66, false) // >
        case 0x5A: excise(from: sequenceStart, to: offset + 1) // Z, DECID: answered as DA1
        case 0x63: terminal.fullReset() // c
        case 0x6E: terminal.invokeCharset(gl: 2) // n
        case 0x6F: terminal.invokeCharset(gl: 3) // o
        case 0x7E: terminal.invokeCharset(gr: 1) // ~
        case 0x7D: terminal.invokeCharset(gr: 2) // }
        case 0x7C: terminal.invokeCharset(gr: 3) // |
        default: break
        }
    }

    // MARK: - CSI

    private mutating func csiDispatch(final: UInt8, at offset: Int64) {
        terminatorPending = false
        guard !paramsOverflowed, params.count < Self.maximumParams else { return }
        if paramDigits > 0 {
            params.append(paramValue)
        }
        guard final == 0x6D || colons == 0 else { return }
                let marker: UInt8? = intermediates.count == 1 ? intermediates[0] : nil
        let first = params.first ?? 0

        switch final {
        case 0x68, 0x6C: // h, l
            let enabled = final == 0x68
            if marker == 0x3F {
                for mode in params {
                    terminal.setDECMode(mode, enabled)
                }
            } else if intermediates.isEmpty {
                for mode in params {
                    terminal.setANSIMode(mode, enabled)
                }
            }
        case 0x6D: // m
            if intermediates.isEmpty {
                applySGR()
            } else if marker == 0x3E {
                terminal.modifyKeyFormat = Array(">".utf8) + serializedParams() + [0x6D]
            } else if marker == 0x3F {
                // XTQMODKEYS.
                excise(from: sequenceStart, to: offset + 1)
            }
        case 0x6E: // n
            if intermediates.isEmpty || marker == 0x3F {
                excise(from: sequenceStart, to: offset + 1) // DSR
            } else if marker == 0x3E {
                terminal.modifyKeyFormat = Array(">".utf8) + serializedParams() + [0x6E]
            }
        case 0x63: // c
            if intermediates.isEmpty || marker == 0x3E || marker == 0x3D {
                excise(from: sequenceStart, to: offset + 1) // DA1, DA2, DA3
            }
        case 0x70: // p
            if intermediates == [0x21], params.isEmpty {
                terminal.softReset() // DECSTR
            } else if intermediates == [0x24] || intermediates == [0x3F, 0x24] {
                excise(from: sequenceStart, to: offset + 1) // DECRQM
            }
        case 0x71: // q
            if intermediates == [0x20] {
                if params.count <= 1 {
                    terminal.cursorStyle = first
                }
            } else if marker == 0x3E {
                excise(from: sequenceStart, to: offset + 1) // XTVERSION
            }
        case 0x72: // r
            if intermediates.isEmpty {
                if params.count <= 2 {
                    terminal.setScrollRegion(top: first, bottom: params.count == 2 ? params[1] : 0)
                }
            } else if marker == 0x3F {
                for mode in params {
                    terminal.restoreDECMode(mode)
                }
            }
        case 0x73: // s
            if intermediates.isEmpty, params.isEmpty, !terminal.decMode(69) {
                terminal.saveCursor()
            } else if marker == 0x3F {
                for mode in params {
                    terminal.saveDECMode(mode)
                }
            }
        case 0x74: // t
            if intermediates.isEmpty, [11, 13, 14, 15, 16, 18, 19, 20, 21].contains(first) {
                excise(from: sequenceStart, to: offset + 1) // XTWINOPS reports
            }
        case 0x75: // u
            if intermediates.isEmpty {
                terminal.restoreCursor()
            } else if marker == 0x3F {
                excise(from: sequenceStart, to: offset + 1) // kitty keyboard query
            } else if marker == 0x3E {
                if params.isEmpty {
                    terminal.kittyPush(0)
                } else if params.count == 1, first <= 31 {
                    terminal.kittyPush(UInt8(first))
                }
            } else if marker == 0x3C {
                terminal.kittyPop(params.count == 1 ? first : 1)
            } else if marker == 0x3D {
                let mode = params.count >= 2 ? params[1] : 1
                if first <= 31, (1 ... 3).contains(mode) {
                    terminal.kittySet(UInt8(first), mode: mode)
                }
            }
        case 0x78: // x
            if intermediates.isEmpty {
                excise(from: sequenceStart, to: offset + 1) // DECREQTPARM
            }
        case 0x79: // y
            if intermediates == [0x2A] {
                excise(from: sequenceStart, to: offset + 1) // DECRQCRA
            }
        default:
            break
        }
    }

    private func serializedParams() -> [UInt8] {
        var out: [UInt8] = []
        for (index, value) in params.enumerated() {
            if index > 0 {
                out.append(colons & (1 << UInt32(index - 1)) != 0 ? 0x3A : 0x3B)
            }
            out += Array(String(value).utf8)
        }
        return out
    }

    private mutating func applySGR() {
        // `CSI m` and `CSI 0 m` reset the pen; a sequence that opens with a
        // reset (`0;1;31`) replaces it.
        let isReset = params.isEmpty || (params == [0])
        let startsWithReset = params.first == 0 && colons & 1 == 0
        terminal.applySGR(serializedParams(), isReset: isReset, startsWithReset: startsWithReset)
    }

    // MARK: - Strings

    /// Applies a finished OSC; true when the replay leaves it out.
    private mutating func finishOSC(end: StringEnd) -> Bool {
        // Ghostty drops an OSC cancelled by CAN or SUB.
        guard end == .terminated else { return false }
        let payload = payload
        var number = 0
        var index = 0
        while index < payload.count, payload[index] >= 0x30, payload[index] <= 0x39, number < 100_000 {
            number = number * 10 + Int(payload[index] - 0x30)
            index += 1
        }
        guard index > 0 else { return false }
        let hasSemicolon = index < payload.count && payload[index] == 0x3B
        let body = hasSemicolon ? Array(payload[(index + 1)...]) : []
        let complete = !payloadOverflowed

        var leaveOut = false
        switch number {
        case 0, 2:
            if complete, hasSemicolon {
                terminal.title = body
            }
        case 4:
            leaveOut = applyPalette(body, complete: complete)
        case 5, 21:
            leaveOut = body.contains(0x3F)
        case 7:
            if complete, hasSemicolon {
                terminal.workingDirectory = body
            }
        case 8:
            if complete, hasSemicolon {
                // `params;uri`, an empty uri ending the link.
                if let separator = body.firstIndex(of: 0x3B), separator + 1 < body.count {
                    terminal.setHyperlink(body)
                } else {
                    terminal.setHyperlink(nil)
                }
            }
        case 9:
            // ConEmu's progress (9;4) is state; anything else is a
            // notification.
            leaveOut = !body.starts(with: [0x34, 0x3B])
        case 10 ... 19:
            leaveOut = applyDynamicColors(from: number - 10, body, complete: complete)
        case 52, 72, 99, 777, 5522:
            // The clipboard, kitty's drag and drop, notifications, and the
            // kitty clipboard: each acts, or answers, every time it is read.
            leaveOut = true
        case 104:
            if body.isEmpty {
                terminal.palette = [:]
            } else {
                for index in body.split(separator: 0x3B).compactMap({ UInt16(String(decoding: $0, as: UTF8.self)) }) {
                    terminal.palette[index] = nil
                }
            }
        case 110 ... 119:
            terminal.dynamicColors[UInt16(number - 110)] = []
        case 1337:
            // iTerm2's: a copy to the clipboard, or a report.
            leaveOut = body.starts(with: Array("Copy".utf8)) || body.starts(with: Array("Report".utf8))
        default:
            break
        }
        return leaveOut
    }

    /// OSC 4: `index;spec` pairs. A spec of `?` asks for the colour — the
    /// whole sequence is then left out, and nothing in it kept.
    private mutating func applyPalette(_ body: [UInt8], complete: Bool) -> Bool {
        let fields = body.split(separator: 0x3B, omittingEmptySubsequences: false)
        var pairs: [(UInt16, [UInt8])] = []
        var index = 0
        while index + 1 < fields.count {
            let spec = Array(fields[index + 1])
            if spec == [0x3F] {
                return true
            }
            if let color = UInt16(String(decoding: fields[index], as: UTF8.self)), color <= 255 {
                pairs.append((color, spec))
            }
            index += 2
        }
        if complete {
            for (color, spec) in pairs {
                terminal.palette[color] = spec
            }
        }
        return false
    }

    /// OSC 10–19: one spec per colour, from the numbered one on.
    private mutating func applyDynamicColors(from first: Int, _ body: [UInt8], complete: Bool) -> Bool {
        let specs = body.split(separator: 0x3B, omittingEmptySubsequences: false).map(Array.init)
        if specs.contains([0x3F]) {
            return true
        }
        if complete {
            for (offset, spec) in specs.enumerated() where first + offset <= 9 && !spec.isEmpty {
                terminal.dynamicColors[UInt16(first + offset)] = spec
            }
        }
        return false
    }

    /// DECRQSS (`$ q`) and XTGETTCAP (`+ q`) are questions. Ghostty acts
    /// on a DCS however it ends.
    private func finishDCS() -> Bool {
        dcsFinal == 0x71 && (dcsIntermediates == [0x24] || dcsIntermediates == [0x2B])
    }

    /// A kitty graphics command (`ESC _ G keys ; payload`) is answered
    /// unless it is quiet (`q=2`) or names no image (`i`, `I`) to answer
    /// about, and a transmission in chunks (`m=1`) is answered after its
    /// last one, by the first chunk's keys: the chain is kept or left out
    /// whole.
    private mutating func finishAPC(end: StringEnd) -> Bool {
        guard payload.first == 0x47 else {
            kittyChain = .none
            return false
        }
        let control = payload.dropFirst().prefix { $0 != 0x3B }
        var keys: [UInt8: Int] = [:]
        var action: UInt8 = 0x74
        for pair in control.split(separator: 0x2C) {
            guard pair.count >= 3, pair[pair.startIndex + 1] == 0x3D else { continue }
            let key = pair[pair.startIndex]
            let value = pair.dropFirst(2)
            if key == 0x61, let character = value.first {
                action = character
            } else if let number = Int(String(decoding: value, as: UTF8.self)) {
                keys[key] = number
            }
        }
        let more = keys[0x6D] == 1
        let leaveOut: Bool
        switch kittyChain {
        case .keep:
            leaveOut = false
        case .excise:
            leaveOut = true
        case .none:
            let quiet = keys[0x71] ?? 0
            let names = (keys[0x69] ?? 0) != 0 || (keys[0x49] ?? 0) != 0
            leaveOut = quiet < 2 && (names || action == 0x71)
        }
        kittyChain = more ? (leaveOut ? .excise : .keep) : .none
        _ = end
        return leaveOut
    }

    // MARK: - ZMODEM

    private mutating func beginZmodem(at start: Int64) {
        zmodem = .data(cancels: 0)
        zmodemStart = start
        promptMarkProgress = 0
        state = .ground
        utf8Remaining = 0
        utf8Lower = 0x80
        utf8Upper = 0xBF
        terminatorPending = false
        clear()
    }

    private mutating func endZmodem(before offset: Int64) {
        exciseConversation(to: offset)
        zmodem = .idle
        recent = 0
    }

    /// The conversation goes, a CAN in its place: the header's own CAN
    /// cancelled whatever sequence it interrupted, and without one that
    /// sequence would run on into the output after the transfer.
    private mutating func exciseConversation(to end: Int64) {
        let lower = max(zmodemStart, 0)
        guard excisions != nil, lower < end else { return }
        excisions?.append(Excision(range: lower ..< end, replacement: [0x18]))
    }

    private mutating func stepZmodem(_ byte: UInt8, at offset: Int64) {
        if trackPromptMark(byte) {
            // The shell is drawing its prompt: the conversation ended
            // before the mark began, and the parser is inside the mark.
            endZmodem(before: offset - 6)
            sequenceStart = offset - 6
            clear()
            head = [0x1B]
            enterString(.oscString)
            payload = Array("133;".utf8) + [byte]
            return
        }
        switch zmodem {
        case .idle:
            return
        case let .data(cancels):
            if byte == 0x18 {
                zmodem = .data(cancels: cancels + 1)
            } else if cancels >= 5 {
                zmodem = .afterCancel
                stepZmodem(byte, at: offset)
            } else if recent & 0xFFFF_FFFF_FFFF == 0x2A2A_1842_3038 {
                zmodem = .finishHex
            } else {
                zmodem = .data(cancels: 0)
            }
        case .afterCancel:
            if byte != 0x08 {
                endZmodem(before: offset)
                ground(byte, at: offset)
            }
        case .finishHex:
            if byte == 0x0D {
                zmodem = .finishTrailer
            }
        case .finishTrailer:
            // CR LF (or 0x8A) and an XON — and another CR where the sender
            // left the terminal cooked, so its LF went out as CR LF.
            if byte == 0x0A || byte == 0x8A || byte == 0x11 || byte == 0x0D {
                break
            } else if byte == 0x4F {
                zmodem = .finishFirstO
            } else {
                endZmodem(before: offset)
                ground(byte, at: offset)
            }
        case .finishFirstO:
            if byte == 0x4F {
                endZmodem(before: offset + 1)
            } else {
                // A lone O after the header is not sz's: the conversation
                // ended before it.
                endZmodem(before: offset - 1)
                ground(0x4F, at: offset - 1)
                ground(byte, at: offset)
            }
        }
    }

    /// `ESC ] 1 3 3 ;` then `A` (prompt) or `D` (command finished).
    private mutating func trackPromptMark(_ byte: UInt8) -> Bool {
        let mark: [UInt8] = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B]
        if promptMarkProgress == mark.count {
            promptMarkProgress = 0
            if byte == 0x41 || byte == 0x44 {
                return true
            }
        }
        if byte == mark[promptMarkProgress] {
            promptMarkProgress += 1
        } else {
            promptMarkProgress = byte == mark[0] ? 1 : 0
        }
        return false
    }
}
