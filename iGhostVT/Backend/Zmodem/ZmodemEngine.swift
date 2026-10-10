//
//  ZmodemEngine.swift
//  iGhostVT
//

import Foundation

enum ZmodemDirection {
    case download
    case upload
}

enum ZmodemTransferPhase: Equatable {
    case active
    case done
    case cancelled
    /// A drop's copy to another device that did not get there; what went
    /// wrong is the caption.
    case failed(String)
}

struct ZmodemTransferInfo: Equatable {
    var direction: ZmodemDirection
    var name: String
    var transferred: UInt64
    var total: UInt64?
    var phase: ZmodemTransferPhase = .active
    /// A drop's copy is held until the tab's own connection is up: the
    /// paste that follows it travels on that connection.
    var isWaitingForConnection = false
}

/// Every mutable field is touched only on `queue`; the public entry points hop
/// onto it. That invariant is what `@unchecked Sendable` asserts.
final class ZmodemEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.zmodem")

    private let sink: @Sendable ([UInt8]) -> Void
    private let passthrough: @Sendable ([UInt8]) -> Void
    private let makeWriter: @Sendable () -> ZmodemFileWriter
    private let requestSource: @Sendable (@escaping @Sendable (ZmodemFileSource?) -> Void) -> Void
    private let onState: @Sendable (ZmodemTransferInfo?) -> Void

    private enum Mode { case idle, awaitingSource, active, discarding }
    private var mode: Mode = .idle
    private var direction: ZmodemDirection = .download
    private var detector = ZmodemDetector()
    private var parser: ZmodemParser?
    private var receiver: ZmodemReceiver?
    private var sender: ZmodemSender?
    private var info: ZmodemTransferInfo?

    private var watchdog: DispatchSourceTimer?
    private static let stallTimeout = 30
    private static let quietSenderTimeout = 10
    // Invalidates a scheduled confirmation-fade when a new transfer starts.
    private var dismissGeneration: UInt64 = 0
    private static let confirmationLinger = 3.0

    init(
        sink: @escaping @Sendable ([UInt8]) -> Void,
        passthrough: @escaping @Sendable ([UInt8]) -> Void,
        makeWriter: @escaping @Sendable () -> ZmodemFileWriter,
        requestSource: @escaping @Sendable (@escaping @Sendable (ZmodemFileSource?) -> Void) -> Void,
        onState: @escaping @Sendable (ZmodemTransferInfo?) -> Void,
    ) {
        self.sink = sink
        self.passthrough = passthrough
        self.makeWriter = makeWriter
        self.requestSource = requestSource
        self.onState = onState
    }

    // MARK: Inputs (any thread)

    func ingest(_ data: Data) {
        let bytes = [UInt8](data)
        queue.async { [weak self] in self?.process(bytes) }
    }

    func cancel() {
        queue.async { [weak self] in self?.abort() }
    }

    func reset() {
        queue.async { [weak self] in self?.teardown(notify: true) }
    }

    /// The link this engine served dropped. Answers whether a transfer was
    /// under way — the other end is still in it, and the next link must
    /// clean up after it (`discardInterruptedTransfer`) — and ends it here
    /// without a word: the caller says what happened, since this engine is
    /// about to be thrown away with whatever it scheduled.
    func abandonForLostLink() -> Bool {
        queue.sync {
            let wasRunning = mode != .idle && mode != .discarding
            if wasRunning {
                AppLog.warning(.zmodem, "link lost mid-transfer direction=\(direction)")
            }
            teardown(notify: false)
            return wasRunning
        }
    }

    /// The link came back to a transfer the last one dropped. The program
    /// on the other end does not know: `sz` goes on streaming the file and
    /// `rz` waits for more. Until its conversation ends, what arrives is
    /// swallowed rather than drawn — and once something of it does arrive,
    /// the program is told to stop. Output that is plain text from the
    /// start (the program already gave up) ends this at once, so nothing is
    /// sent to a shell that would read it as keystrokes.
    func discardInterruptedTransfer() {
        queue.async { [weak self] in
            guard let self else { return }
            mode = .discarding
            discardTail = []
            hasCancelledInterrupted = false
            let generation = dismissGeneration
            queue.asyncAfter(deadline: .now() + Self.discardLimit) { [weak self] in
                guard let self, mode == .discarding, dismissGeneration == generation else { return }
                AppLog.warning(.zmodem, "interrupted transfer: no end seen in \(Int(Self.discardLimit)) s, showing output again")
                mode = .idle
            }
        }
    }

    private var discardTail: [UInt8] = []
    private var hasCancelledInterrupted = false
    private static let discardLimit: TimeInterval = 15

    private func discard(_ bytes: [UInt8]) {
        // ZDLE is in every ZMODEM header and, escaped, all through its data;
        // terminal text has no use for it.
        let looksLikeText = !bytes.contains(0x18)
        if !hasCancelledInterrupted {
            if looksLikeText {
                AppLog.info(.zmodem, "interrupted transfer: the other end already stopped")
                mode = .idle
                process(bytes)
                return
            }
            hasCancelledInterrupted = true
            AppLog.info(.zmodem, "interrupted transfer still running on the other end: cancelling it")
            emit(ZmodemEncoder.cancelSequence())
        }
        let window = discardTail + bytes
        if let end = ZmodemStreamScanner.endIndex(in: window) {
            AppLog.info(.zmodem, "interrupted transfer ended on the other end")
            mode = .idle
            discardTail = []
            let rest = Array(window[end...])
            if !rest.isEmpty {
                process(rest)
            }
            return
        }
        discardTail = Array(window.suffix(64))
    }

    // MARK: Engine queue

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func process(_ bytes: [UInt8]) {
        switch mode {
        case .idle:
            let result = detector.feed(bytes)
            if !result.passthrough.isEmpty {
                passthrough(result.passthrough)
            }
            if let trigger = result.trigger {
                AppLog.info(.zmodem, "trigger \(trigger) in=\(bytes.count)B parserBytes=\(result.parserBytes.count)B")
                start(trigger, initial: result.parserBytes)
            }
        case .awaitingSource, .active:
            AppLog.verbose(.zmodem, "ingest \(bytes.count)B mode=\(mode) [\(Self.hex(bytes))]")
            parser?.feed(bytes)
        case .discarding:
            discard(bytes)
        }
    }

    private func start(_ trigger: ZmodemDetector.Trigger, initial: [UInt8]) {
        dismissGeneration &+= 1
        let parser = ZmodemParser()
        parser.onEvent = { [weak self] event in self?.dispatch(event) }
        self.parser = parser
        armWatchdog()

        switch trigger {
        case .download:
            direction = .download
            let writer = makeWriter()
            let receiver = ZmodemReceiver(send: { [weak self] in self?.emit($0) }, writer: writer)
            receiver.onProgress = { [weak self] name, got, total in
                self?.report(name: name, transferred: got, total: total)
            }
            receiver.onFinished = { [weak self] ok in self?.finished(ok) }
            self.receiver = receiver
            mode = .active
            report(name: "", transferred: 0, total: nil)
            receiver.begin()
            parser.feed(initial)

        case .upload:
            direction = .upload
            mode = .awaitingSource
            report(name: "", transferred: 0, total: nil)
            parser.feed(initial)
            requestSource { [weak self] source in
                self?.deliverSource(source)
            }
        }
    }

    private func deliverSource(_ source: ZmodemFileSource?) {
        queue.async { [weak self] in self?.attachSource(source) }
    }

    private func attachSource(_ source: ZmodemFileSource?) {
        AppLog.info(.zmodem, "attachSource mode=\(mode) source=\(source != nil)")
        guard mode == .awaitingSource else {
            source?.finish(completed: false)
            return
        }
        guard let source else {
            abort()
            return
        }
        let sender = ZmodemSender(send: { [weak self] in self?.emit($0) }, source: source)
        sender.onProgress = { [weak self] name, got, total in
            self?.report(name: name, transferred: got, total: total)
        }
        sender.onFinished = { [weak self] ok in self?.finished(ok) }
        self.sender = sender
        mode = .active
        sender.begin()
    }

    private func dispatch(_ event: ZParserEvent) {
        petWatchdog()
        switch event {
        case let .header(header): AppLog.info(.zmodem, "<- header \(header.type) pos=\(header.position)")
        case let .data(bytes, end): AppLog.verbose(.zmodem, "<- data \(bytes.count)B end=\(end)")
        case .badCRC: AppLog.warning(.zmodem, "<- BADCRC")
        case .abort: AppLog.warning(.zmodem, "<- ABORT")
        case .noise: break
        }
        switch direction {
        case .download:
            receiver?.handle(event)
            // The sender answers a ZEOF's ZRINIT at once if it is still
            // there; one that went quiet is not worth the full stall.
            if receiver?.isAwaitingSenderAfterCompleteFiles == true {
                watchdog?.schedule(deadline: .now() + .seconds(Self.quietSenderTimeout))
            }
        case .upload: sender?.handle(event)
        }
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        AppLog.verbose(.zmodem, "-> \(bytes.count)B [\(Self.hex(bytes))]")
        sink(bytes)
    }

    private var lastStateEmit = DispatchTime.now()
    private static let progressThrottleNanos: UInt64 = 100_000_000

    private func report(name: String, transferred: UInt64, total: UInt64?) {
        let info = ZmodemTransferInfo(direction: direction, name: name, transferred: transferred, total: total)
        self.info = info
        // A streaming download reports thousands of times a second; a main-actor
        // hop each would bury the main thread. Emit the first update then at
        // most ~10 Hz — `finished` always sends the final one from `info`.
        let now = DispatchTime.now()
        let elapsed = now.uptimeNanoseconds &- lastStateEmit.uptimeNanoseconds
        guard transferred == 0 || elapsed >= Self.progressThrottleNanos else {
            // The newest figure goes out when the window closes rather than
            // with the next chunk: over a slow link data comes in bursts
            // seconds apart, and dropping each burst's last update left the
            // bar standing on a stale value until the next one.
            guard !isTrailingEmitScheduled else { return }
            isTrailingEmitScheduled = true
            let generation = dismissGeneration
            queue.asyncAfter(deadline: lastStateEmit + .nanoseconds(Int(Self.progressThrottleNanos))) { [weak self] in
                guard let self else { return }
                isTrailingEmitScheduled = false
                guard generation == dismissGeneration, mode == .active, let info = self.info else { return }
                lastStateEmit = DispatchTime.now()
                onState(info)
            }
            return
        }
        lastStateEmit = now
        onState(info)
    }

    private var isTrailingEmitScheduled = false

    private func finished(_ ok: Bool) {
        AppLog.info(.zmodem, "finished ok=\(ok) direction=\(direction)")
        // A successful download confirms "Saved …" after the save picker (posted
        // by the file bridge), so suppress the pill's own confirmation here.
        if ok, direction == .download {
            teardown(notify: true)
            return
        }
        let confirmation = info.map {
            ZmodemTransferInfo(
                direction: $0.direction,
                name: $0.name,
                transferred: $0.transferred,
                total: $0.total,
                phase: ok ? .done : .cancelled,
            )
        }
        teardown(notify: false)
        guard let confirmation else {
            self.onState(nil)
            return
        }
        info = confirmation
        onState(confirmation)
        dismissGeneration &+= 1
        let generation = dismissGeneration
        queue.asyncAfter(deadline: .now() + Self.confirmationLinger) { [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            self.info = nil
            onState(nil)
        }
    }

    private func abort() {
        guard mode != .idle else { return }
        AppLog.warning(.zmodem, "abort mode=\(mode) direction=\(direction)")
        switch direction {
        case .download:
            if receiver != nil {
                receiver?.cancel(); return
            } // cancel() tears down via onFinished
        case .upload:
            if sender != nil {
                sender?.cancel(); return
            }
        }
        emit(ZmodemEncoder.cancelSequence())
        teardown(notify: true)
    }

    private func teardown(notify: Bool) {
        cancelWatchdog()
        dismissGeneration &+= 1
        mode = .idle
        parser = nil
        receiver = nil
        sender = nil
        detector = ZmodemDetector()
        if notify, info != nil {
            info = nil
            onState(nil)
        }
    }

    // MARK: Watchdog

    private func armWatchdog() {
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Self.stallTimeout))
        timer.setEventHandler { [weak self] in self?.stalled() }
        watchdog = timer
        timer.resume()
    }

    private func stalled() {
        if direction == .download, let receiver, receiver.senderWentQuiet() {
            AppLog.info(.zmodem, "sender went quiet after its last file arrived whole; done")
            return
        }
        abort()
    }

    private func petWatchdog() {
        watchdog?.schedule(deadline: .now() + .seconds(Self.stallTimeout))
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}

/// Where a ZMODEM conversation sits in a stream of terminal output, for the
/// output that never goes through an engine. A transfer is ZDLE-escaped
/// binary — on screen it is a wall of garbage that can retitle the tab —
/// and two kinds of output reach the surface without an engine to swallow
/// it: the replay an attach hands back (the daemon keeps bytes, so a
/// transfer from minutes ago is in there), and what a transfer cut off by a
/// dropped link keeps sending after the link comes back.
///
/// A conversation starts at a hex header (`**` ZDLE `B`) and ends at
/// either mark a sender leaves: the ZFIN exchange (with sz's `OO` after
/// it), or a cancel — a run of CAN, which lrzsz also sends when it gives
/// up, followed by its backspaces. Neither can occur inside the data: a
/// ZDLE there is always escaped (`0x18 0x58`), never doubled or followed
/// by `B`.
enum ZmodemStreamScanner {
    private static let start: [UInt8] = [0x2A, 0x2A, 0x18, 0x42]
    private static let finish: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x38]
    private static let cancelRun = 5

    /// The first conversation's start in `bytes`, if any.
    static func startIndex(in bytes: [UInt8], from: Int = 0) -> Int? {
        index(of: start, in: bytes, from: from)
    }

    /// Just past the end of the conversation `bytes` is inside of (they
    /// begin within it), or nil when it has not ended in them.
    static func endIndex(in bytes: [UInt8], from: Int = 0) -> Int? {
        var cursor = from
        while cursor < bytes.count {
            let next = bytes[cursor]
            if next == 0x18 {
                var run = cursor
                while run < bytes.count, bytes[run] == 0x18 {
                    run += 1
                }
                if run - cursor >= cancelRun {
                    while run < bytes.count, bytes[run] == 0x08 {
                        run += 1
                    }
                    return run
                }
                cursor = run
                continue
            }
            if next == 0x2A, matches(finish, in: bytes, at: cursor) {
                // The header's hex digits and CRC, then CR, LF (or 0x8A)
                // and an XON; sz answers the receiver's ZFIN with "OO".
                var end = cursor + finish.count
                while end < bytes.count, bytes[end] != 0x0D {
                    end += 1
                }
                guard end < bytes.count else { return nil }
                end += 1
                while end < bytes.count, [0x0A, 0x8A, 0x11].contains(bytes[end]) {
                    end += 1
                }
                if end + 1 < bytes.count, bytes[end] == 0x4F, bytes[end + 1] == 0x4F {
                    end += 2
                }
                return end
            }
            cursor += 1
        }
        return nil
    }

    /// `replay` with every conversation in it taken out — one that never
    /// ended runs to the end — and whether there was any.
    static func strip(_ replay: [UInt8]) -> (bytes: [UInt8], removed: Bool) {
        var kept: [UInt8] = []
        kept.reserveCapacity(replay.count)
        var cursor = 0
        var removed = false
        while let header = startIndex(in: replay, from: cursor) {
            // sz announces itself as "rz\r" before its first header.
            var begin = header
            if header - cursor >= 3, Array(replay[(header - 3) ..< header]) == Array("rz\r".utf8) {
                begin = header - 3
            }
            kept.append(contentsOf: replay[cursor ..< begin])
            removed = true
            guard let end = endIndex(in: replay, from: header + start.count) else {
                return (kept, true)
            }
            cursor = end
        }
        kept.append(contentsOf: replay[cursor...])
        return (kept, removed)
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard haystack.count >= needle.count, from <= haystack.count - needle.count else { return nil }
        for position in from ... (haystack.count - needle.count) where matches(needle, in: haystack, at: position) {
            return position
        }
        return nil
    }

    private static func matches(_ needle: [UInt8], in haystack: [UInt8], at position: Int) -> Bool {
        guard position + needle.count <= haystack.count else { return false }
        for offset in 0 ..< needle.count where haystack[position + offset] != needle[offset] {
            return false
        }
        return true
    }
}
