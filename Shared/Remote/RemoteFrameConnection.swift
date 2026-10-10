import Compression
import Foundation
import Network
import XPC

/// `IOWire` frames over an `NWConnection`: what the app and
/// `ighostvtd-remote` exchange once TLS is up.
///
/// Everything happens on `queue`, the connection's own. Frames are handed
/// out whole; a header that is not one of ours, or a payload that does not
/// decode, ends the connection. Output not yet taken by the network is
/// counted (`pendingByteCount`) so a caller can stop producing while a slow
/// link catches up.
final class RemoteFrameConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue

    /// A decoded frame. `nil` objects never reach it.
    var onFrame: ((IOWire.Header, xpc_object_t) -> Void)?
    /// The connection is ready (TLS done), once.
    var onReady: (() -> Void)?
    /// The connection is over, once, whatever ended it.
    var onClosed: ((String) -> Void)?
    /// `pendingByteCount` changed.
    var onPendingChange: ((Int) -> Void)?

    /// The largest payload a received frame may carry; a header announcing
    /// more ends the connection before any of it is buffered or decoded.
    /// Raise it once the other end is trusted with more.
    var maximumPayloadByteCount = IOWire.maximumPayloadByteCount
    /// Sends large payloads compressed (`RemoteFrameCompression`): the
    /// host's side of a link whose hello offered it.
    var compressesOutput = false
    /// Takes compressed frames: the device's side, which offered it. A
    /// compressed frame on a link that never offered ends the connection.
    var acceptsCompressedInput = false
    /// Frames left to send plain after one that did not shrink: a stream
    /// that does not compress (`sz` of a zip) is not tried frame by frame.
    private var plainFramesAfterMiss = 0
    private(set) var pendingByteCount = 0
    /// Frame bytes sent and received over this connection, the two ends
    /// counting the same stream: what the link window
    /// (`RemoteAccess.linkWindowByteCount`) is measured in. A compressed
    /// frame counts as the plain one it stands for — counted as it crossed
    /// the wire, a window of 16 KiB output events that pack into 200 B each
    /// held ninety times the terminal output it was there to bound.
    private(set) var sentByteCount: UInt64 = 0
    private(set) var receivedByteCount: UInt64 = 0
    /// What actually arrived, compressed or not, for measuring.
    private(set) var receivedWireByteCount: UInt64 = 0
    /// LZFSE's decoder scratch, made with the first compressed frame and
    /// used only on `queue`.
    private var decodeScratch: UnsafeMutableRawPointer?
    private var acknowledgedByteCount: UInt64 = 0
    private var buffer: [UInt8] = []
    private var isClosed = false
    private var isReady = false
    /// `closeWhenFlushed` is waiting for the last sends to leave.
    private var isDraining = false
    /// Held while draining: the owner has usually let go by then, and the
    /// send completions only hold this weakly.
    private var retainedWhileDraining: RemoteFrameConnection?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    deinit {
        decodeScratch?.deallocate()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            onReady?()
            receive()
        case let .waiting(error):
            close(reason: "waiting: \(error)")
        case let .failed(error):
            close(reason: "failed: \(error)")
        case .cancelled:
            close(reason: "cancelled")
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }
            if let data, !data.isEmpty {
                receivedWireByteCount += UInt64(data.count)
                buffer.append(contentsOf: data)
                guard drainFrames() else { return }
            }
            if let error {
                close(reason: "receive: \(error)")
            } else if isComplete {
                close(reason: "closed by the other end")
            } else {
                receive()
            }
        }
    }

    /// Hands out every whole frame in the buffer. False when the link
    /// carried something that is not a frame, which closes it.
    private func drainFrames() -> Bool {
        var offset = 0
        defer {
            if offset > 0 {
                buffer.removeFirst(offset)
            }
        }
        while buffer.count - offset >= IOWire.headerByteCount {
            let flags = buffer[offset + RemoteFrameCompression.flagsOffset]
            let isCompressed = flags == RemoteFrameCompression.compressedFlag
            guard flags == 0 || (isCompressed && acceptsCompressedInput) else {
                close(reason: "unexpected frame flags \(flags)")
                return false
            }
            let header = buffer.withUnsafeBytes { bytes in
                IOWire.decodeHeader(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
            }
            guard let header else {
                close(reason: "unreadable frame header")
                return false
            }
            guard header.payloadByteCount <= maximumPayloadByteCount else {
                close(reason: "a \(header.payloadByteCount)-byte frame, over the \(maximumPayloadByteCount) allowed")
                return false
            }
            let end = offset + IOWire.headerByteCount + header.payloadByteCount
            guard buffer.count >= end else { break }
            var plainByteCount = header.payloadByteCount
            if isCompressed, decodeScratch == nil {
                decodeScratch = RemoteFrameCompression.makeDecodeScratch()
            }
            let object = buffer.withUnsafeBytes { bytes -> xpc_object_t? in
                let payload = UnsafeRawBufferPointer(rebasing: bytes[(offset + IOWire.headerByteCount) ..< end])
                guard isCompressed else { return IOCodec.decode(payload) }
                guard let plain = RemoteFrameCompression.decompress(
                    payload,
                    limit: maximumPayloadByteCount,
                    scratch: decodeScratch,
                ) else {
                    return nil
                }
                plainByteCount = plain.count
                return plain.withUnsafeBytes { IOCodec.decode($0) }
            }
            receivedByteCount += UInt64(IOWire.headerByteCount + plainByteCount)
            offset = end
            guard let object else {
                close(reason: "undecodable frame payload")
                return false
            }
            onFrame?(header, object)
            if isClosed {
                return false
            }
        }
        return true
    }

    /// False when the object could not be encoded or the link is gone.
    @discardableResult
    func send(_ kind: IOWire.Kind, tag: UInt64, object: xpc_object_t) -> Bool {
        guard !isClosed, !isDraining else { return false }
        var payload: [UInt8] = []
        guard IOCodec.encode(object, into: &payload), payload.count <= IOWire.maximumPayloadByteCount else {
            return false
        }
        var compressed: [UInt8]?
        if compressesOutput, payload.count >= RemoteFrameCompression.minimumByteCount {
            if plainFramesAfterMiss > 0 {
                plainFramesAfterMiss -= 1
            } else {
                compressed = RemoteFrameCompression.frame(kind: kind, tag: tag, payload: payload)
                // One small frame of escapes that will not pack says
                // little about the stream; a large one does.
                if compressed == nil, payload.count >= RemoteFrameCompression.missByteCount {
                    plainFramesAfterMiss = RemoteFrameCompression.plainFramesAfterMiss
                }
            }
        }
        let frame = compressed ?? {
            var frame: [UInt8] = []
            frame.reserveCapacity(IOWire.headerByteCount + payload.count)
            IOWire.appendHeader(
                IOWire.Header(kind: kind, peer: 0, tag: tag, payloadByteCount: payload.count),
                to: &frame,
            )
            frame.append(contentsOf: payload)
            return frame
        }()
        let count = frame.count
        sentByteCount += UInt64(IOWire.headerByteCount + payload.count)
        pendingByteCount += count
        onPendingChange?(pendingByteCount)
        connection.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            pendingByteCount -= count
            onPendingChange?(pendingByteCount)
            if let error {
                close(reason: "send: \(error)")
            } else if isDraining, pendingByteCount == 0 {
                close(reason: "flushed")
            }
        })
        return true
    }

    /// The device's half of the link window: once another
    /// `RemoteAccess.linkReceiptByteCount` has arrived, tells the host how
    /// much, in a `ping` that wants no reply — a host before the window
    /// answers such a ping with nothing and reads no field of it.
    func acknowledgeReceived() {
        guard receivedByteCount - acknowledgedByteCount >= RemoteAccess.linkReceiptByteCount else { return }
        acknowledgedByteCount = receivedByteCount
        let receipt = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(receipt, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(receipt, iGhostVTWireKey.operation, iGhostVTOperation.ping.rawValue)
        xpc_dictionary_set_uint64(receipt, iGhostVTWireKey.received, receivedByteCount)
        send(.request, tag: 0, object: receipt)
    }

    /// Closes once everything sent so far has left — a cancel would drop
    /// it, and the last frame is often the one that matters (a close, a
    /// detach) — or after `timeout`, whichever is first. Nothing more may
    /// be sent meanwhile, and nothing more is delivered.
    func closeWhenFlushed(timeout: TimeInterval = 2) {
        guard !isClosed, !isDraining else { return }
        guard isReady, pendingByteCount > 0 else {
            close(reason: "closed")
            return
        }
        isDraining = true
        retainedWhileDraining = self
        onFrame = nil
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.close(reason: "flush timed out")
        }
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        retainedWhileDraining = nil
        decodeScratch?.deallocate()
        decodeScratch = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClosed = onClosed
        self.onClosed = nil
        onFrame = nil
        onReady = nil
        onClosed?(reason)
    }
}

/// Frame compression on a remote link, host to device only.
///
/// A frame whose payload is compressed says so in the header's first
/// padding byte (`flagsOffset`, which `IOWire` writes as zero and never
/// reads) and carries the payload's plain length, then LZFSE of it.
///
/// Compression under encryption lets the size of what is sent say
/// something about what it held. Each frame is compressed on its own, with
/// no dictionary carried from one to the next, so one frame's size says
/// nothing about another's contents (CRIME). Within one frame it still can
/// (BREACH): if a frame holds both a secret and text someone else chose —
/// a log they can write to, scrolling past a token — and they can watch the
/// link's record sizes (the relay, the local network) while that frame is
/// sent again and again with their guesses in it, its size tells them
/// whether a guess matched. A terminal resends nothing on its own, which is
/// what keeps that from being practical; it is a cost accepted for the
/// replay and the output it shrinks. The device's input is never
/// compressed — keystrokes are what such a measurement would be after — and
/// neither is a frame under `minimumByteCount`, which leaves an echoed key
/// the size it always was.
enum RemoteFrameCompression {
    /// What a device's hello offers in `iGhostVTWireKey.compression`.
    static let algorithm: UInt64 = 1
    static let flagsOffset = 5
    static let compressedFlag: UInt8 = 1
    /// The sender's threshold only: a reader takes any length, so a later
    /// patch that compresses smaller frames still reads on this one.
    static let minimumByteCount = 1024
    static let plainFramesAfterMiss = 32
    /// The smallest frame whose failing to pack sends the next ones plain.
    static let missByteCount = 8 * 1024
    private static let lengthByteCount = 4

    /// LZFSE's encoder wants about 680 KB of scratch, which it would
    /// otherwise allocate and free on every frame. One is kept for the
    /// process — only a host ever compresses — and a frame that finds it
    /// in use lets the encoder allocate its own.
    private static let scratchLock = NSLock()
    private nonisolated(unsafe) static let scratch = UnsafeMutableRawPointer.allocate(
        byteCount: compression_encode_scratch_buffer_size(COMPRESSION_LZFSE),
        alignment: 16,
    )

    /// The device's offer, on its hello.
    static func offer(in hello: xpc_object_t) {
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.compression, algorithm)
    }

    /// The host's reading of a hello: whether to compress for this device.
    static func isOffered(in hello: xpc_object_t) -> Bool {
        xpc_dictionary_get_uint64(hello, iGhostVTWireKey.compression) == algorithm
    }

    /// A whole compressed frame — header, plain length, LZFSE — encoded in
    /// place, or nil when it would save less than an eighth.
    static func frame(kind: IOWire.Kind, tag: UInt64, payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty, payload.count <= Int(UInt32.max) else { return nil }
        let prefix = IOWire.headerByteCount + lengthByteCount
        let capacity = payload.count - payload.count / 8
        let frame = [UInt8](unsafeUninitializedCapacity: prefix + capacity) { buffer, count in
            count = 0
            guard let base = buffer.baseAddress else { return }
            let usesScratch = scratchLock.try()
            defer {
                if usesScratch {
                    scratchLock.unlock()
                }
            }
            let written = payload.withUnsafeBufferPointer { source in
                compression_encode_buffer(
                    base + prefix, capacity,
                    source.baseAddress!, source.count,
                    usesScratch ? scratch : nil, COMPRESSION_LZFSE,
                )
            }
            guard written > 0 else { return }
            var header: [UInt8] = []
            IOWire.appendHeader(
                IOWire.Header(kind: kind, peer: 0, tag: tag, payloadByteCount: lengthByteCount + written),
                to: &header,
            )
            header[flagsOffset] = compressedFlag
            IOWire.appendUInt32(UInt32(payload.count), to: &header)
            for (index, byte) in header.enumerated() {
                (base + index).initialize(to: byte)
            }
            count = prefix + written
        }
        return frame.isEmpty ? nil : frame
    }

    /// The plain payload, or nil for a body that does not unpack to the
    /// length it states: a length over `limit` is refused before anything
    /// is decoded, so a small frame cannot unpack into more than a plain
    /// one may carry. Bytes after the end of the LZFSE stream are not
    /// looked at; only the host, past its proof, sends these at all.
    static func decompress(
        _ body: UnsafeRawBufferPointer,
        limit: Int,
        scratch: UnsafeMutableRawPointer? = nil,
    ) -> [UInt8]? {
        guard body.count > lengthByteCount else { return nil }
        let length = Int(IOWire.loadUInt32(body, at: 0))
        guard length > 0, length <= limit else { return nil }
        let source = UnsafeRawBufferPointer(rebasing: body[lengthByteCount...])
        var written = 0
        // One byte to spare, so a body that holds more than it says fills
        // it and is caught.
        let plain = [UInt8](unsafeUninitializedCapacity: length + 1) { destination, count in
            written = compression_decode_buffer(
                destination.baseAddress!, destination.count,
                source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count,
                scratch, COMPRESSION_LZFSE,
            )
            count = written == length ? length : 0
        }
        guard written == length else { return nil }
        return plain
    }

    /// The decoder's scratch, for a link to keep while it reads compressed
    /// frames: without one, LZFSE allocates its own on every frame.
    static func makeDecodeScratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: compression_decode_scratch_buffer_size(COMPRESSION_LZFSE),
            alignment: 16,
        )
    }
}
