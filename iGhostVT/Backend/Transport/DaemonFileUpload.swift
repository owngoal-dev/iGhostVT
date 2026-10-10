import Foundation
import XPC

/// Copies one local file onto a daemon's device (`iGhostVTOperation.uploadFile`)
/// and answers with the path it has there — what a drop on a tab whose shell
/// runs on another device pastes, since no path on this one means anything
/// to that shell.
///
/// Over a link of its own, never the tab's: a file is megabytes, and the
/// tab's link is where keystrokes go. The parts go out back to back, in file
/// order, `window` of them unanswered at most, so a fast network is not
/// paced at a round trip per part and a slow one holds a bounded amount in
/// flight.
///
/// Built for a weak network:
/// - A link that answers nothing for `replyTimeout` is dead, whatever it
///   says. The clock restarts with every answer, so a slow link that is
///   still moving is not mistaken for a dead one, and after a timeout the
///   window halves (growing back one part at a time as answers come), so a
///   link too slow for eight parts in flight still gets one through.
/// - A dead link is replaced, the host is asked how much of the file it
///   holds — the upload outlives the link on its side — and the copy
///   carries on from there. Parts the old link sent may still land after the
///   question; the host takes them as the repeats they are.
/// - The id is this side's, so a begin sent again after its answer was lost
///   finds the same upload rather than making a second file.
/// - It gives up when nothing has moved for `stallLimit`, when the host no
///   longer knows the upload, when the file changes, or when the task is
///   cancelled — and in every one of those cases tells the host to remove
///   what it has, over a fresh link, so no partial file is left behind.
final class DaemonFileUpload: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? {
            message
        }
    }

    private let endpoint: DaemonEndpoint
    private let file: URL
    private let name: String
    private let size: UInt64
    private let progress: @Sendable (UInt64) -> Void
    private let id = UInt64.random(in: 1 ... .max)
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.upload", qos: .userInitiated)

    private static let maximumWindow = 8
    private static let replyTimeout: TimeInterval = 30
    private static let stallLimit: TimeInterval = 180

    // Only touched by the task running `run()`.
    private var link: DaemonLink?
    private var linkState: LinkState?
    private var window = maximumWindow

    init(
        endpoint: DaemonEndpoint,
        file: URL,
        name: String,
        size: UInt64,
        progress: @escaping @Sendable (UInt64) -> Void,
    ) {
        self.endpoint = endpoint
        self.file = file
        self.name = name
        self.size = size
        self.progress = progress
    }

    /// The path the file has on the host once all of it is there.
    func run() async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let identity = Self.identity(of: handle)
        guard let identity, identity.size == size else {
            throw Failure(message: String(localized: "The file changed while it was being copied."))
        }
        var begun = false
        do {
            let path = try await begin()
            begun = true
            try await transfer(handle)
            // Read to the end, but an edit in place keeps the size: the
            // modification time says whether the bytes sent are the file's.
            guard Self.identity(of: handle) == identity else {
                throw Failure(message: String(localized: "The file changed while it was being copied."))
            }
            try Task.checkCancellation()
            drop()
            return path
        } catch {
            drop()
            if begun || error is CancellationError {
                abandon()
            }
            throw error
        }
    }

    // MARK: - Stages

    private func begin() async throws -> String {
        let lastProgress = Date()
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard let link = await liveLink() else {
                try await backOff(&attempt, since: lastProgress)
                continue
            }
            let message = Self.message()
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
            xpc_dictionary_set_string(message, iGhostVTWireKey.fileName, name)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.fileSize, size)
            guard let reply = await send(message, over: link).reply() else {
                drop()
                try await backOff(&attempt, since: lastProgress)
                continue
            }
            let code = Self.code(of: reply)
            guard code == .success, let path = xpc_dictionary_get_string(reply, iGhostVTWireKey.path) else {
                throw Failure(message: Self.reason(reply, code: code, isBegin: true))
            }
            AppLog.info(.drop, "upload \(name): \(size) byte(s) to \(String(cString: path))")
            return String(cString: path)
        }
    }

    private func transfer(_ handle: FileHandle) async throws {
        var held: UInt64 = 0
        var mustAsk = false
        var lastProgress = Date()
        var attempt = 0
        while held < size {
            try Task.checkCancellation()
            guard let link = await liveLink() else {
                try await backOff(&attempt, since: lastProgress)
                mustAsk = true
                continue
            }
            if mustAsk {
                let message = Self.message()
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
                guard let reply = await send(message, over: link).reply() else {
                    drop()
                    try await backOff(&attempt, since: lastProgress)
                    continue
                }
                let code = Self.code(of: reply)
                guard code == .success else {
                    throw Failure(message: Self.reason(reply, code: code, isBegin: false))
                }
                held = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.offset)
                mustAsk = false
                AppLog.info(.drop, "upload \(name): resuming at \(held) of \(size), \(window) part(s) in flight")
                progress(held)
                if held >= size {
                    break
                }
            }
            let before = held
            let outcome = try await pump(from: held, handle: handle, over: link)
            held = outcome.held
            if held > before {
                lastProgress = Date()
                attempt = 0
                progress(held)
            }
            switch outcome.end {
            case .done:
                break
            case .linkFailed:
                AppLog.info(.drop, "upload \(name): link failed at \(held) of \(size)")
                drop()
                mustAsk = true
                if held < size {
                    try await backOff(&attempt, since: lastProgress)
                }
            case .misaligned:
                AppLog.info(.drop, "upload \(name): the host holds other than \(held), asking")
                mustAsk = true
                try await backOff(&attempt, since: lastProgress)
            case let .refused(message):
                AppLog.warning(.drop, "upload \(name): refused at \(held): \(message)")
                throw Failure(message: message)
            }
        }
    }

    // MARK: - Parts

    private enum PumpEnd {
        case done
        /// No answer, or the link went: the host may hold more than `held`.
        case linkFailed
        /// The host holds something other than what was sent against.
        case misaligned
        case refused(String)
    }

    private enum PartResult: Sendable {
        case accepted(UInt64)
        case misaligned
        case linkFailed
        case refused(String)
    }

    /// Sends parts from `start` until the file is all there or something
    /// goes wrong. Each part is sent here, in file order — sent from its own
    /// task it would leave whenever that task ran, and the host would see
    /// the parts out of order — and a task only waits for its answer.
    private func pump(
        from start: UInt64,
        handle: FileHandle,
        over link: DaemonLink,
    ) async throws -> (held: UInt64, end: PumpEnd) {
        try handle.seek(toOffset: start)
        // Read once: the parts' tasks must not touch `linkState` while this
        // task may replace it.
        guard let state = linkState else { return (start, .linkFailed) }
        let id = id
        var next = start
        var held = start
        var end = PumpEnd.done
        var acceptedSinceGrowth = 0
        // A cancel closes the link, which answers every part in flight at
        // once; the group would otherwise wait them out.
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: PartResult.self) { group in
                var inFlight = 0
                func sendNext() throws {
                    try Task.checkCancellation()
                    let count = Int(min(UInt64(iGhostVTProtocol.uploadChunkByteCount), size - next))
                    guard count > 0, let data = try? handle.read(upToCount: count), data.count == count else {
                        state.markLost()
                        link.cancel()
                        throw Failure(message: String(localized: "The file changed while it was being copied."))
                    }
                    let message = Self.message()
                    xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
                    xpc_dictionary_set_uint64(message, iGhostVTWireKey.offset, next)
                    data.withUnsafeBytes { buffer in
                        xpc_dictionary_set_data(message, iGhostVTWireKey.data, buffer.baseAddress!, buffer.count)
                    }
                    next += UInt64(count)
                    let pending = send(message, over: link)
                    group.addTask {
                        guard let reply = await pending.reply() else { return .linkFailed }
                        let code = Self.code(of: reply)
                        switch code {
                        case .success:
                            return .accepted(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.offset))
                        case .invalidRequest where xpc_dictionary_get_value(reply, iGhostVTWireKey.offset) != nil:
                            return .misaligned
                        default:
                            return .refused(Self.reason(reply, code: code, isBegin: false))
                        }
                    }
                    inFlight += 1
                }
                while inFlight < window, next < size {
                    try sendNext()
                }
                while let result = try await group.next() {
                    inFlight -= 1
                    switch result {
                    case let .accepted(offset):
                        held = max(held, offset)
                        // The host is ahead of what this link sent: parts an
                        // earlier link sent landed after all. Nothing to send
                        // twice.
                        if held > next {
                            next = held
                            try handle.seek(toOffset: next)
                        }
                        acceptedSinceGrowth += 1
                        if window < Self.maximumWindow, acceptedSinceGrowth >= window {
                            window += 1
                            acceptedSinceGrowth = 0
                        }
                        while inFlight < window, next < size {
                            try sendNext()
                        }
                        progress(held)
                        continue
                    case .misaligned:
                        end = .misaligned
                    case .linkFailed:
                        end = .linkFailed
                        if state.didTimeOut {
                            window = max(1, window / 2)
                        }
                    case let .refused(message):
                        end = .refused(message)
                    }
                    // The rest of the window was sent against a stream that
                    // already broke. Closing the link answers those parts at
                    // once, and the next round asks the host what it holds.
                    state.markLost()
                    link.cancel()
                    group.cancelAll()
                    return
                }
            }
        } onCancel: {
            state.markLost()
            link.cancel()
        }
        try Task.checkCancellation()
        return (held, end)
    }

    // MARK: - The link

    private func liveLink() async -> DaemonLink? {
        if let link, linkState?.isLost == false {
            return link
        }
        drop()
        guard let fresh = endpoint.makeLink(queue: queue) else { return nil }
        let state = LinkState()
        fresh.activate { event in
            if case .lost = event {
                state.markLost()
            }
        }
        link = fresh
        linkState = state
        guard let reply = await send(Self.message(.hello), over: fresh).reply(),
              Self.code(of: reply) == .success
        else {
            drop()
            return nil
        }
        return fresh
    }

    private func drop() {
        link?.cancel()
        link = nil
        linkState = nil
    }

    /// Tells the host to give the upload up and remove what it has, over a
    /// link of its own — the one in use may be the reason it failed. Best
    /// effort, and not waited for: one the host never hears of it gives up
    /// itself after a quarter of an hour.
    private func abandon() {
        let endpoint = endpoint
        let id = id
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.upload.abandon", qos: .utility)
        guard let link = endpoint.makeLink(queue: queue) else { return }
        link.activate { _ in }
        link.send(Self.message(.hello)) { _ in
            let message = Self.message()
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.upload, id)
            xpc_dictionary_set_bool(message, iGhostVTWireKey.cancel, true)
            link.send(message) { _ in
                link.cancel()
            }
        }
        queue.asyncAfter(deadline: .now() + Self.replyTimeout) {
            link.cancel()
        }
    }

    /// Sends now and hands back the answer to wait for: nil for a lost link,
    /// one that answered nothing at all for `replyTimeout` (which also marks
    /// it lost), or a reply that is not the protocol's. Uses the current
    /// link's state, which `liveLink` sets before its own first request.
    private func send(_ message: xpc_object_t, over link: DaemonLink) -> PendingReply {
        let pending = PendingReply()
        let state = linkState
        let sentAt = Date()
        watch(pending, state: state, from: sentAt, after: Self.replyTimeout)
        link.send(message) { reply in
            let valid = xpc_get_type(reply) == iGhostVTXPC.typeDictionary
                && xpc_dictionary_get_uint64(reply, iGhostVTWireKey.version) == iGhostVTProtocol.version
            if valid {
                state?.noteAnswer()
            } else {
                state?.markLost()
            }
            pending.resolve(valid ? MessageBox(reply) : nil)
        }
        return pending
    }

    /// The watchdog: a request gives up only once the link has answered
    /// *nothing* for `replyTimeout` since it was sent. Behind two megabytes
    /// of earlier parts on a slow link it may wait far longer than that,
    /// for as long as answers keep coming.
    private func watch(_ pending: PendingReply, state: LinkState?, from sentAt: Date, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard !pending.isResolved else { return }
            let quiet = Date().timeIntervalSince(max(sentAt, state?.lastAnswer ?? sentAt))
            if quiet >= Self.replyTimeout || self == nil {
                if pending.resolve(nil) {
                    state?.markTimedOut()
                }
            } else {
                self?.watch(pending, state: state, from: sentAt, after: Self.replyTimeout - quiet)
            }
        }
    }

    /// Waits before the next try, longer each time, and gives up once
    /// nothing has moved for `stallLimit`.
    private func backOff(_ attempt: inout Int, since lastProgress: Date) async throws {
        guard Date().timeIntervalSince(lastProgress) < Self.stallLimit else {
            throw Failure(message: String(localized: "The other device stopped answering."))
        }
        let delay = min(8.0, 0.5 * pow(2, Double(attempt)))
        attempt += 1
        AppLog.info(.drop, "upload \(name): link down, trying again in \(delay)s")
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: - Wire

    private static func message(_ operation: iGhostVTOperation = .uploadFile) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        return message
    }

    private static func code(of reply: xpc_object_t) -> iGhostVTReplyCode {
        iGhostVTReplyCode(rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code)) ?? .operationFailed
    }

    private static func reason(_ reply: xpc_object_t, code: iGhostVTReplyCode, isBegin: Bool) -> String {
        if let message = xpc_dictionary_get_string(reply, iGhostVTWireKey.errorMessage) {
            return String(cString: message)
        }
        switch code {
        case .unknownSession:
            return String(localized: "The other device gave up on the file.")
        case .invalidRequest where isBegin:
            // A daemon that has never heard of the operation says only this.
            return String(localized: "The other device's iGhostVT is too old to receive files. Update it there.")
        default:
            return String(localized: "The other device could not take the file.")
        }
    }

    private struct FileIdentity: Equatable {
        var size: UInt64
        var modified: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.size == rhs.size && lhs.modified.tv_sec == rhs.modified.tv_sec
                && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }
    }

    private static func identity(of handle: FileHandle) -> FileIdentity? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return FileIdentity(size: UInt64(info.st_size), modified: info.st_mtimespec)
    }
}

/// What one link has done: whether it is gone, whether it went quiet, and
/// when it last answered anything.
private final class LinkState: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false
    private var timedOut = false
    private var answeredAt: Date?

    var isLost: Bool {
        lock.withLock { lost }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    var lastAnswer: Date? {
        lock.withLock { answeredAt }
    }

    func markLost() {
        lock.withLock { lost = true }
    }

    func markTimedOut() {
        lock.withLock {
            lost = true
            timedOut = true
        }
    }

    func noteAnswer() {
        lock.withLock { answeredAt = Date() }
    }
}

/// An answer that may come before or after someone waits for it.
private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var value: MessageBox?
    private var waiter: CheckedContinuation<MessageBox?, Never>?

    var isResolved: Bool {
        lock.withLock { resolved }
    }

    /// False when it was already resolved: the first answer stands.
    @discardableResult
    func resolve(_ value: MessageBox?) -> Bool {
        let (won, waiter): (Bool, CheckedContinuation<MessageBox?, Never>?) = lock.withLock {
            guard !resolved else { return (false, nil) }
            resolved = true
            self.value = value
            let waiter = self.waiter
            self.waiter = nil
            return (true, waiter)
        }
        waiter?.resume(returning: value)
        return won
    }

    /// The answer, or nil at once when the waiting task is cancelled.
    func reply() async -> xpc_object_t? {
        let box: MessageBox? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: Bool = lock.withLock {
                    if resolved {
                        return true
                    }
                    waiter = continuation
                    return false
                }
                if ready {
                    continuation.resume(returning: lock.withLock { value })
                }
            }
        } onCancel: {
            resolve(nil)
        }
        return box?.message
    }
}

private struct MessageBox: @unchecked Sendable {
    let message: xpc_object_t
    init(_ message: xpc_object_t) {
        self.message = message
    }
}
