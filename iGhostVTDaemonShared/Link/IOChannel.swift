import Darwin
import Dispatch
import XPC

/// One end of the `ighostvtd` ↔ `ighostvtd-io` socket.
///
/// Framing, non-blocking writes, and the two hooks flow control hangs on:
/// the reader can be paused (the proxy stops taking output it cannot
/// deliver, so the socket fills, so the io side stops reading its PTYs),
/// and the writer reports how much it is holding (the io side pauses its
/// PTYs on that; nothing on either side grows without bound).
///
/// Everything runs on `queue`, which is the process's control queue.
final class IOChannel {
    typealias FrameHandler = (IOWire.Header, UnsafeRawBufferPointer) -> Void

    /// A complete frame arrived. The payload pointer is valid for the call.
    var onFrame: FrameHandler?
    /// The other end went away (EOF, a reset, or a malformed frame). Fires
    /// once; the descriptor is closed by then.
    var onClosed: (() -> Void)?
    /// The outbound backlog changed size, in bytes.
    var onPendingChange: ((Int) -> Void)?

    private var pendingByteCount = 0

    private let queue: DispatchQueue
    private var descriptor: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private(set) var isReadSuspended = false
    private var isWriteArmed = false
    private var isClosed = false

    private var inbound: [UInt8] = []
    private var outbound: [UInt8] = []
    private var outboundOffset = 0

    /// Past this a drained accumulator is handed back to the allocator
    /// rather than kept for the next frame — for both directions.
    private static let retainedCapacity = 256 * 1024

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    }

    func activate() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        // The descriptor outlives the sources watching it: closing it under
        // a live kqueue registration is the documented way to confuse
        // libdispatch. The write source is cancelled first (in `close`), so
        // by the time this runs nothing else refers to the descriptor.
        let descriptor = descriptor
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        readSource = source
        source.activate()
    }

    // MARK: - Sending

    /// Encodes and queues one frame. False when the object cannot be
    /// carried (see `IOCodec`); nothing is sent then.
    @discardableResult
    func send(_ kind: IOWire.Kind, peer: UInt64, tag: UInt64, object: xpc_object_t?) -> Bool {
        guard !isClosed else { return false }
        var payload: [UInt8] = []
        if let object {
            guard IOCodec.encode(object, into: &payload) else { return false }
        }
        guard payload.count <= IOWire.maximumPayloadByteCount else { return false }
        let header = IOWire.Header(kind: kind, peer: peer, tag: tag, payloadByteCount: payload.count)
        outbound.reserveCapacity(outbound.count + IOWire.headerByteCount + payload.count)
        IOWire.appendHeader(header, to: &outbound)
        outbound.append(contentsOf: payload)
        flushOutbound()
        return true
    }

    /// Writes everything queued, blocking. For the moment before an exit:
    /// a reply that never left the process is a reply nobody got.
    func flushBlocking() {
        guard !isClosed else { return }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) & ~O_NONBLOCK)
        outbound.withUnsafeBytes { bytes in
            let rest = UnsafeRawBufferPointer(rebasing: bytes[outboundOffset...])
            _ = writeFully(descriptor, rest)
        }
        outbound.removeAll()
        outboundOffset = 0
        updatePending()
    }

    private func flushOutbound() {
        while outboundOffset < outbound.count {
            let written = outbound.withUnsafeBytes { bytes -> Int in
                Darwin.write(descriptor, bytes.baseAddress! + outboundOffset, bytes.count - outboundOffset)
            }
            if written > 0 {
                outboundOffset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN {
                armWriteSource()
                updatePending()
                return
            }
            // EPIPE, ECONNRESET: the other end is gone.
            close()
            return
        }
        outbound.removeAll(keepingCapacity: outbound.capacity <= Self.retainedCapacity)
        outboundOffset = 0
        disarmWriteSource()
        updatePending()
    }

    private func armWriteSource() {
        guard !isWriteArmed else { return }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.flushOutbound()
            }
            // Created suspended by libdispatch; `activate` counts as the
            // first resume, so the arm/disarm pair below stays balanced.
            writeSource = source
            source.activate()
            isWriteArmed = true
            return
        }
        writeSource?.resume()
        isWriteArmed = true
    }

    private func disarmWriteSource() {
        guard isWriteArmed else { return }
        writeSource?.suspend()
        isWriteArmed = false
    }

    private func updatePending() {
        let pending = outbound.count - outboundOffset
        guard pending != pendingByteCount else { return }
        pendingByteCount = pending
        onPendingChange?(pending)
    }

    // MARK: - Receiving

    /// Stops taking frames off the socket until `resumeReading`. Balanced
    /// by a flag, so repeated calls are harmless.
    func suspendReading() {
        guard !isReadSuspended, let readSource else { return }
        isReadSuspended = true
        readSource.suspend()
    }

    func resumeReading() {
        guard isReadSuspended, let readSource else { return }
        isReadSuspended = false
        readSource.resume()
        // Frames that arrived with the one that caused the pause are still
        // in the accumulator, and the socket will not fire for them.
        queue.async { [weak self] in
            guard let self, !isClosed, !isReadSuspended else { return }
            if !dispatchCompleteFrames() {
                close()
            }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { destination -> Int in
                Darwin.read(descriptor, destination.baseAddress!, destination.count)
            }
            if count > 0 {
                inbound.append(contentsOf: chunk[0 ..< count])
                guard dispatchCompleteFrames() else {
                    close()
                    return
                }
                // One read per event keeps a flood of output from starving
                // the queue; the source fires again if more is waiting.
                return
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN {
                return
            }
            close()
            return
        }
    }

    /// False on a malformed header — the link is out of sync and the only
    /// safe thing is to drop it.
    private func dispatchCompleteFrames() -> Bool {
        var consumed = 0
        var malformed = false
        inbound.withUnsafeBytes { bytes in
            while bytes.count - consumed >= IOWire.headerByteCount {
                let rest = UnsafeRawBufferPointer(rebasing: bytes[consumed...])
                guard let header = IOWire.decodeHeader(rest) else {
                    malformed = true
                    return
                }
                let frameCount = IOWire.headerByteCount + header.payloadByteCount
                guard rest.count >= frameCount else { return }
                let payload = UnsafeRawBufferPointer(
                    rebasing: rest[IOWire.headerByteCount ..< frameCount],
                )
                onFrame?(header, payload)
                consumed += frameCount
                if isClosed || isReadSuspended {
                    // A handler paused us (or closed us); leave the rest
                    // for when reading resumes.
                    return
                }
            }
        }
        if malformed {
            return false
        }
        if consumed > 0 {
            if consumed == inbound.count {
                inbound.removeAll(keepingCapacity: inbound.capacity <= Self.retainedCapacity)
            } else {
                inbound.removeFirst(consumed)
            }
        }
        return true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let writeSource {
            if !isWriteArmed {
                writeSource.resume()
            }
            writeSource.cancel()
            self.writeSource = nil
        }
        if let readSource {
            if isReadSuspended {
                readSource.resume()
                isReadSuspended = false
            }
            readSource.cancel()
            self.readSource = nil
        } else {
            Darwin.close(descriptor)
        }
        descriptor = -1
        outbound.removeAll()
        outboundOffset = 0
        inbound.removeAll()
        pendingByteCount = 0
        onClosed?()
    }
}
