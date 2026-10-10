//
//  ZmodemTransfer.swift
//  iGhostVT
//

import Foundation

protocol ZmodemFileWriter: AnyObject, Sendable {
    func beginFile(name: String, size: UInt64?) -> Bool
    func write(_ bytes: [UInt8])
    func finishFile()
    func finish(completed: Bool)
}

struct ZmodemOutgoingFile: Sendable {
    var name: String
    var size: UInt64
    var read: @Sendable (_ offset: UInt64, _ maxLength: Int) -> [UInt8]
}

protocol ZmodemFileSource: AnyObject, Sendable {
    func nextFile() -> ZmodemOutgoingFile?
    func finish(completed: Bool)
}

// MARK: - Receiver (download: shell `sz` → us)

final class ZmodemReceiver {
    private let send: ([UInt8]) -> Void
    // Strong: nothing the writer holds points back, and a weak one would be
    // gone the moment the engine's start() returns.
    private let writer: ZmodemFileWriter

    var onProgress: (String, UInt64, UInt64?) -> Void = { _, _, _ in }
    var onFinished: (Bool) -> Void = { _ in }

    private enum Phase { case awaitingFile, receivingData, done }
    private var phase: Phase = .awaitingFile
    private var expectingFileInfo = false
    private var expectingSinitAck = false
    private var offset: UInt64 = 0
    private var name = ""
    private var size: UInt64?
    private var finished = false
    /// Files whose ZEOF named the length received, every byte of it.
    private var completedFileCount = 0
    /// The last file ended whole and nothing of another has begun.
    private var isBetweenCompleteFiles = false

    init(send: @escaping ([UInt8]) -> Void, writer: ZmodemFileWriter) {
        self.send = send
        self.writer = writer
    }

    func begin() {
        sendRInit()
    }

    private func sendRInit() {
        send(ZmodemEncoder.hexHeader(.rinit, 0, 0, 0, Zmodem.CANFDX | Zmodem.CANOVIO | Zmodem.CANFC32))
    }

    func handle(_ event: ZParserEvent) {
        guard !finished else { return }
        switch event {
        case let .header(header):
            handleHeader(header)
        case let .data(bytes, end):
            handleData(bytes, end: end)
        case .abort:
            finish(completed: false)
        case .badCRC:
            if phase == .receivingData {
                sendPositionHeader(.rpos, offset)
            } else {
                send(ZmodemEncoder.hexHeader(.nak))
            }
        case .noise:
            break
        }
    }

    private func handleHeader(_ header: ZHeader) {
        switch header.type {
        case .rqinit:
            sendRInit()
        case .sinit:
            expectingSinitAck = true
        case .file:
            expectingFileInfo = true
            isBetweenCompleteFiles = false
        case .data:
            offset = UInt64(header.position)
            phase = .receivingData
        case .eof:
            if phase == .receivingData {
                writer.finishFile()
                if UInt64(header.position) == offset, size.map({ $0 == offset }) ?? true {
                    completedFileCount += 1
                    isBetweenCompleteFiles = true
                }
            }
            phase = .awaitingFile
            offset = 0
            sendRInit()
        case .fin:
            send(ZmodemEncoder.hexHeader(.fin))
            finish(completed: true)
        default:
            break
        }
    }

    private func handleData(_ bytes: [UInt8], end: ZSubpacketEnd) {
        if expectingSinitAck {
            expectingSinitAck = false
            send(ZmodemEncoder.hexHeader(.ack))
            return
        }
        if expectingFileInfo {
            expectingFileInfo = false
            let info = Self.parseFileInfo(bytes)
            name = info.name
            size = info.size
            if writer.beginFile(name: info.name, size: info.size) {
                offset = 0
                onProgress(name, 0, size)
                sendPositionHeader(.rpos, 0)
            } else {
                send(ZmodemEncoder.hexHeader(.skip))
            }
            return
        }
        guard phase == .receivingData else { return }
        writer.write(bytes)
        offset += UInt64(bytes.count)
        onProgress(name, offset, size)
        if end.wantsAck {
            sendPositionHeader(.ack, offset)
        }
    }

    private func sendPositionHeader(_ type: ZFrameType, _ offset: UInt64) {
        let position = ZHeader.position(UInt32(truncatingIfNeeded: offset))
        send(ZmodemEncoder.hexHeader(type, position.0, position.1, position.2, position.3))
    }

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        phase = .done
        writer.finish(completed: completed)
        onFinished(completed)
    }

    func cancel() {
        guard !finished else { return }
        send(ZmodemEncoder.cancelSequence())
        finish(completed: false)
    }

    /// The sender went quiet. Over a congested link `sz` can write a whole
    /// file into buffers that take minutes to drain, then give up waiting
    /// for the ZRINIT that answers its ZEOF and exit — while every byte is
    /// still on its way here. A transfer whose files all ended whole is
    /// therefore done, not cancelled; anything else is a stall. Answers
    /// whether it finished; nothing is sent either way, since there is no
    /// sender left to tell and a cancel would land in its shell as ^X.
    var isAwaitingSenderAfterCompleteFiles: Bool {
        !finished && completedFileCount > 0 && isBetweenCompleteFiles
    }

    func senderWentQuiet() -> Bool {
        guard isAwaitingSenderAfterCompleteFiles else { return false }
        finish(completed: true)
        return true
    }

    static func parseFileInfo(_ bytes: [UInt8]) -> (name: String, size: UInt64?) {
        guard let nul = bytes.firstIndex(of: 0) else {
            return (String(decoding: bytes, as: UTF8.self), nil)
        }
        let name = String(decoding: bytes[0 ..< nul], as: UTF8.self)
        let rest = bytes[(nul + 1)...]
        let restEnd = rest.firstIndex(of: 0) ?? rest.endIndex
        let info = String(decoding: rest[rest.startIndex ..< restEnd], as: UTF8.self)
        let size = info.split(separator: " ").first.flatMap { UInt64($0) }
        return (name, size)
    }
}

// MARK: - Sender (upload: us → shell `rz`)

final class ZmodemSender {
    private let send: ([UInt8]) -> Void
    /// Strong, same reason as ZmodemReceiver's writer.
    private let source: ZmodemFileSource

    var onProgress: (String, UInt64, UInt64?) -> Void = { _, _, _ in }
    var onFinished: (Bool) -> Void = { _ in }

    private let blockSize = 8192
    /// Unacked bytes in flight. Windowing avoids a round trip per 8 KiB; 256 KiB
    /// stays well under the daemon's 4 MiB input buffer.
    private let window: UInt64 = 256 * 1024

    private enum Phase { case sentFile, sendingData, awaitingEOFAck, finishing, done }
    private var phase: Phase = .sentFile
    private var current: ZmodemOutgoingFile?
    private var offset: UInt64 = 0
    private var ackedOffset: UInt64 = 0
    private var sentLastBlock = false
    private var finished = false

    init(send: @escaping ([UInt8]) -> Void, source: ZmodemFileSource) {
        self.send = send
        self.source = source
    }

    func begin() {
        startNextFile()
    }

    private func startNextFile() {
        guard let file = source.nextFile() else {
            sendFin()
            return
        }
        current = file
        offset = 0
        phase = .sentFile
        send(ZmodemEncoder.bin32Header(.file))
        send(ZmodemEncoder.dataSubpacket32(Self.fileInfo(file), end: .wait))
        onProgress(file.name, 0, file.size)
    }

    func handle(_ event: ZParserEvent) {
        guard !finished else { return }
        switch event {
        case let .header(header):
            handleHeader(header)
        case .abort:
            finish(completed: false)
        case .data, .badCRC, .noise:
            break
        }
    }

    private func handleHeader(_ header: ZHeader) {
        switch header.type {
        case .rpos:
            offset = UInt64(header.position)
            ackedOffset = offset
            phase = .sendingData
            sentLastBlock = false
            sendPositionHeader(.data, offset)
            pumpWindow()
        case .ack:
            guard phase == .sendingData else { break }
            ackedOffset = max(ackedOffset, UInt64(header.position))
            if sentLastBlock, ackedOffset >= offset {
                sendPositionHeader(.eof, offset)
                phase = .awaitingEOFAck
            } else {
                pumpWindow()
            }
        case .rinit:
            if phase == .awaitingEOFAck {
                startNextFile()
            }
        case .skip:
            startNextFile()
        case .fin:
            send(Array("OO".utf8))
            finish(completed: true)
        default:
            break
        }
    }

    private func pumpWindow() {
        guard let file = current else { return }
        while !sentLastBlock, offset - ackedOffset < window {
            let chunk = file.read(offset, blockSize)
            if chunk.isEmpty, offset < file.size {
                cancel()
                return
            }
            offset += UInt64(chunk.count)
            let isLast = offset >= file.size
            send(ZmodemEncoder.dataSubpacket32(chunk, end: isLast ? .wait : .query))
            sentLastBlock = isLast
            if !chunk.isEmpty {
                onProgress(file.name, offset, file.size)
            }
        }
    }

    private func sendFin() {
        phase = .finishing
        send(ZmodemEncoder.hexHeader(.fin))
    }

    private func sendPositionHeader(_ type: ZFrameType, _ offset: UInt64) {
        let position = ZHeader.position(UInt32(truncatingIfNeeded: offset))
        if type == .data {
            send(ZmodemEncoder.bin32Header(type, position.0, position.1, position.2, position.3))
        } else {
            send(ZmodemEncoder.hexHeader(type, position.0, position.1, position.2, position.3))
        }
    }

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        phase = .done
        source.finish(completed: completed)
        onFinished(completed)
    }

    func cancel() {
        guard !finished else { return }
        send(ZmodemEncoder.cancelSequence())
        finish(completed: false)
    }

    static func fileInfo(_ file: ZmodemOutgoingFile) -> [UInt8] {
        var bytes = Array(file.name.utf8)
        bytes.append(0)
        let meta = "\(file.size) 0 0 0 1 \(file.size)"
        bytes.append(contentsOf: meta.utf8)
        bytes.append(0)
        return bytes
    }
}
