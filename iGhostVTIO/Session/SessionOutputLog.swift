import Foundation

/// A session's recent output, and what an attach hands back from it.
///
/// The bytes are kept with their place in the session's whole output
/// stream — `startOffset` is the stream offset of the first one — and with
/// the terminal state the output before them left (`startState`), read off
/// the bytes as they are trimmed. That makes two replays possible:
///
/// - a continuation, for a client that says how much of the stream it
///   already holds: everything after that, exactly as the program wrote
///   it, so a link that dropped for a moment resumes without a gap, and
///   without the history the client already shows being printed again;
/// - a rebuild, for a client starting fresh, or one whose place has been
///   trimmed away: the state the trimmed output left, written back as
///   sequences, then the newest output from a sequence boundary, with
///   whatever a terminal would answer or act on again left out
///   (`TerminalStreamTracker`).
///
/// Trimmed in batches: once the buffer holds twice `capacity`, the tail is
/// copied into fresh storage and the old storage freed. Not `removeFirst`
/// on every append — on a `Data` that only moves the slice's start, so the
/// storage kept every byte the session had ever printed: a flood grew
/// `ighostvtd-io` by its whole output and nothing gave it back. The copy
/// moves each byte at most once more, and the tracker reads each once.
struct SessionOutputLog {
    enum Replay {
        /// The stream from the offset the client named, unchanged.
        case continuation(Data)
        /// The screen rebuilt. `endsInTransfer`: a ZMODEM transfer is still
        /// going, and was left out with the rest of its conversation.
        case rebuilt(Data, endsInTransfer: Bool)
    }

    let capacity: Int
    private var buffer = Data()
    private(set) var startOffset: UInt64 = 0
    private var startState = TerminalStreamTracker()

    init(capacity: Int = iGhostVTProtocol.sessionReplayByteCount) {
        self.capacity = capacity
    }

    /// The stream offset just past the newest byte: how much the session
    /// has printed, all told.
    var endOffset: UInt64 {
        startOffset + UInt64(buffer.count)
    }

    /// Bytes held, trimmed or not — what the session costs.
    var storageByteCount: Int {
        buffer.count
    }

    /// The newest `capacity` bytes as they are.
    var rawTail: Data {
        Data(buffer.suffix(capacity))
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
        guard buffer.count > 2 * capacity else { return }
        let dropped = buffer.count - capacity
        let base = Int64(truncatingIfNeeded: startOffset)
        buffer.withUnsafeBytes { bytes in
            startState.consume(UnsafeRawBufferPointer(rebasing: bytes[0 ..< dropped]), at: base)
        }
        buffer = Data(buffer.suffix(capacity))
        startOffset += UInt64(dropped)
    }

    /// A continuation from `offset` when the bytes after it are all still
    /// here and no more than a replay's worth; a rebuild otherwise.
    func replay(resumingFrom offset: UInt64?) -> Replay {
        // Compared before anything is subtracted: the offset is the
        // client's, and an overflow trap here ends every shell.
        if let offset, offset >= startOffset, offset <= endOffset, endOffset - offset <= UInt64(capacity) {
            let skipped = Int(offset - startOffset)
            return .continuation(buffer.subdata(in: buffer.startIndex + skipped ..< buffer.endIndex))
        }
        return rebuilt()
    }

    func rebuilt() -> Replay {
        var tracker = startState
        let base = Int64(truncatingIfNeeded: startOffset)
        return buffer.withUnsafeBytes { bytes -> Replay in
            let count = bytes.count
            let windowStart = max(0, count - capacity)
            if windowStart > 0 {
                tracker.consume(UnsafeRawBufferPointer(rebasing: bytes[0 ..< windowStart]), at: base)
            }
            // Forward to the first point Ghostty is between sequences,
            // characters and transfers. What is passed over is not lost to
            // the state: the tracker read it.
            var start = windowStart
            while start < count, !tracker.isQuiescent {
                tracker.consume(UnsafeRawBufferPointer(rebasing: bytes[start ..< start + 1]), at: base + Int64(start))
                start += 1
            }
            let startTerminal = tracker.terminal
            guard start < count else {
                // The whole window is one unfinished sequence or transfer:
                // put Ghostty's parser where it would be, so the live bytes
                // that finish it are not printed.
                let out = startTerminal.preamble() + tracker.continuationPrefix
                return .rebuilt(Data(out), endsInTransfer: tracker.isInZmodemConversation)
            }
            tracker.beginRecording()
            tracker.consume(UnsafeRawBufferPointer(rebasing: bytes[start ..< count]), at: base + Int64(start))
            let end = base + Int64(count)
            let endsInTransfer = tracker.isInZmodemConversation
            var out = startTerminal.includingSettings(touchedBy: tracker.terminal).preamble()
            var cursor = start
            for excision in Self.merged(tracker.takeExcisions(finishingAt: end)) {
                let lower = min(count, max(cursor, Int(excision.range.lowerBound - base)))
                let upper = min(count, max(lower, Int(excision.range.upperBound - base)))
                if lower > cursor {
                    out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[cursor ..< lower]))
                }
                out += excision.replacement
                cursor = max(cursor, upper)
            }
            if cursor < count {
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[cursor ..< count]))
            }
            return .rebuilt(Data(out), endsInTransfer: endsInTransfer)
        }
    }

    /// Ordered, with overlaps joined: a conversation's start is found
    /// three or six bytes after it began, behind whatever was recorded
    /// meanwhile. A joined stretch keeps what stands in for the first.
    private static func merged(_ excisions: [TerminalStreamTracker.Excision]) -> [TerminalStreamTracker.Excision] {
        var result: [TerminalStreamTracker.Excision] = []
        for excision in excisions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = result.last, excision.range.lowerBound < last.range.upperBound {
                result[result.count - 1].range = last.range.lowerBound ..< max(last.range.upperBound, excision.range.upperBound)
            } else {
                result.append(excision)
            }
        }
        return result
    }
}
