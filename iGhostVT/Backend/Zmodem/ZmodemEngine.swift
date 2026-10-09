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

    private enum Mode { case idle, awaitingSource, active }
    private var mode: Mode = .idle
    private var direction: ZmodemDirection = .download
    private var detector = ZmodemDetector()
    private var parser: ZmodemParser?
    private var receiver: ZmodemReceiver?
    private var sender: ZmodemSender?
    private var info: ZmodemTransferInfo?

    private var watchdog: DispatchSourceTimer?
    private static let stallTimeout = 30
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
        case .download: receiver?.handle(event)
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
        guard transferred == 0 || now.uptimeNanoseconds &- lastStateEmit.uptimeNanoseconds >= Self.progressThrottleNanos else {
            return
        }
        lastStateEmit = now
        onState(info)
    }

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
        timer.setEventHandler { [weak self] in self?.abort() }
        watchdog = timer
        timer.resume()
    }

    private func petWatchdog() {
        watchdog?.schedule(deadline: .now() + .seconds(Self.stallTimeout))
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
