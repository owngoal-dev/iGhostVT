import Darwin
import XPC

/// The wire between `ighostvtd` and `ighostvtd-io`.
///
/// `ighostvtd` is a launchd job and lives under the jetsam limit launchd
/// gives daemons (6 MB on the device); the PTYs, the replay buffers, and
/// the shells therefore live in `ighostvtd-io`, a child it spawns, and the
/// daemon itself is a transparent proxy between the app's XPC connections
/// and that child. Every XPC dictionary the app sends is serialized as-is,
/// stamped with the peer it came from and a reply tag, and written to the
/// socket; replies and events come back the same way and are rebuilt as
/// XPC dictionaries for the right peer. The proxy interprets nothing but
/// one operation code, so the protocol can grow without it changing.
///
/// A frame is a fixed header followed by an encoded XPC object:
///
///     u32 payload length  u8 kind  u8×3 reserved  u64 peer  u64 tag  payload
///
/// Little-endian throughout — both ends are the same build on the same
/// machine. `tag` is 0 for a request that wants no reply (the app sent it
/// without `_with_reply`) and for events.
enum IOWire {
    static let headerByteCount = 24
    /// A request may carry `iGhostVTProtocol.maximumMessageDataByteCount`
    /// of data (a paste) plus its keys; an attach reply carries a replay
    /// buffer. Anything past this is a corrupt link, not a message.
    static let maximumPayloadByteCount = 4 * 1024 * 1024

    /// The descriptor `ighostvtd-io` inherits the socket on, and the
    /// argument that names it.
    static let socketDescriptor: Int32 = 3
    static let socketArgument = "--socket-fd"
    static let executableName = "ighostvtd-io"

    enum Kind: UInt8 {
        /// Proxy → io: a client request. Wants a reply iff `tag != 0`.
        case request = 1
        /// io → proxy: the reply to the request with this tag.
        case reply = 2
        /// io → proxy: an unsolicited event for the peer.
        case event = 3
        /// Proxy → io: the peer's connection is gone; detach it everywhere.
        case peerGone = 4
    }

    struct Header {
        var kind: Kind
        var peer: UInt64
        var tag: UInt64
        var payloadByteCount: Int
    }

    static func appendHeader(_ header: Header, to buffer: inout [UInt8]) {
        appendUInt32(UInt32(header.payloadByteCount), to: &buffer)
        buffer.append(header.kind.rawValue)
        buffer.append(contentsOf: [0, 0, 0])
        appendUInt64(header.peer, to: &buffer)
        appendUInt64(header.tag, to: &buffer)
    }

    /// `nil` for a header that is not one of ours; the link is then dead.
    static func decodeHeader(_ bytes: UnsafeRawBufferPointer) -> Header? {
        guard bytes.count >= headerByteCount else { return nil }
        let length = Int(loadUInt32(bytes, at: 0))
        guard let kind = Kind(rawValue: bytes[4]), length <= maximumPayloadByteCount else { return nil }
        return Header(
            kind: kind,
            peer: loadUInt64(bytes, at: 8),
            tag: loadUInt64(bytes, at: 16),
            payloadByteCount: length,
        )
    }

    static func appendUInt32(_ value: UInt32, to buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    static func appendUInt64(_ value: UInt64, to buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    static func loadUInt32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    static func loadUInt64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

/// Serializes the XPC objects the protocol uses — and only those: a
/// message carrying anything else (a file descriptor, a mach port, an
/// endpoint) is refused rather than half-forwarded.
///
///     u8 type, then
///       uint64 / int64: 8 bytes      bool: 1 byte
///       string / data:  u32 length, bytes
///       array:          u32 count, values
///       dictionary:     u32 count, (u32 key length, key, value)…
enum IOCodec {
    private enum Tag: UInt8 {
        case uint64 = 1
        case int64 = 2
        case bool = 3
        case string = 4
        case data = 5
        case array = 6
        case dictionary = 7
    }

    private static let maximumDepth = 8

    /// False when the object holds a type this codec does not carry.
    /// `buffer` may then hold a partial encoding; the caller discards it.
    static func encode(_ object: xpc_object_t, into buffer: inout [UInt8]) -> Bool {
        encode(object, into: &buffer, depth: 0)
    }

    private static func encode(_ object: xpc_object_t, into buffer: inout [UInt8], depth: Int) -> Bool {
        guard depth < maximumDepth else { return false }
        let type = xpc_get_type(object)
        if type == iGhostVTXPC.typeUInt64 {
            buffer.append(Tag.uint64.rawValue)
            IOWire.appendUInt64(xpc_uint64_get_value(object), to: &buffer)
        } else if type == iGhostVTXPC.typeInt64 {
            buffer.append(Tag.int64.rawValue)
            IOWire.appendUInt64(UInt64(bitPattern: xpc_int64_get_value(object)), to: &buffer)
        } else if type == iGhostVTXPC.typeBool {
            buffer.append(Tag.bool.rawValue)
            buffer.append(xpc_bool_get_value(object) ? 1 : 0)
        } else if type == iGhostVTXPC.typeString {
            let length = xpc_string_get_length(object)
            guard let pointer = xpc_string_get_string_ptr(object) else { return false }
            buffer.append(Tag.string.rawValue)
            IOWire.appendUInt32(UInt32(length), to: &buffer)
            buffer.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: length))
        } else if type == iGhostVTXPC.typeData {
            let length = xpc_data_get_length(object)
            buffer.append(Tag.data.rawValue)
            IOWire.appendUInt32(UInt32(length), to: &buffer)
            if length > 0, let pointer = xpc_data_get_bytes_ptr(object) {
                buffer.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: length))
            }
        } else if type == iGhostVTXPC.typeArray {
            let count = xpc_array_get_count(object)
            buffer.append(Tag.array.rawValue)
            IOWire.appendUInt32(UInt32(count), to: &buffer)
            for index in 0 ..< count {
                guard encode(xpc_array_get_value(object, index), into: &buffer, depth: depth + 1) else {
                    return false
                }
            }
        } else if type == iGhostVTXPC.typeDictionary {
            buffer.append(Tag.dictionary.rawValue)
            IOWire.appendUInt32(UInt32(xpc_dictionary_get_count(object)), to: &buffer)
            var succeeded = true
            _ = xpc_dictionary_apply(object) { key, value in
                let keyLength = strlen(key)
                IOWire.appendUInt32(UInt32(keyLength), to: &buffer)
                buffer.append(contentsOf: UnsafeRawBufferPointer(start: key, count: keyLength))
                succeeded = encode(value, into: &buffer, depth: depth + 1)
                return succeeded
            }
            return succeeded
        } else {
            return false
        }
        return true
    }

    /// The object the bytes encode, `nil` for anything malformed. A
    /// truncated or oversized count is malformed, not partially decoded.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> xpc_object_t? {
        var cursor = Cursor(bytes: bytes)
        guard let object = decodeValue(&cursor, depth: 0), cursor.offset == bytes.count else {
            return nil
        }
        return object
    }

    /// Copies every entry of `source` into `destination` — how a decoded
    /// reply lands in the reply object XPC tied to the request.
    static func copyEntries(from source: xpc_object_t, into destination: xpc_object_t) {
        _ = xpc_dictionary_apply(source) { key, value in
            xpc_dictionary_set_value(destination, key, value)
            return true
        }
    }

    private struct Cursor {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        var remaining: Int {
            bytes.count - offset
        }

        mutating func takeUInt8() -> UInt8? {
            guard remaining >= 1 else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func takeUInt32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            defer { offset += 4 }
            return IOWire.loadUInt32(bytes, at: offset)
        }

        mutating func takeUInt64() -> UInt64? {
            guard remaining >= 8 else { return nil }
            defer { offset += 8 }
            return IOWire.loadUInt64(bytes, at: offset)
        }

        /// A length-prefixed run of bytes, bounded by what is left.
        mutating func takeBytes() -> UnsafeRawBufferPointer? {
            guard let length = takeUInt32(), Int(length) <= remaining else { return nil }
            defer { offset += Int(length) }
            return UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + Int(length)])
        }
    }

    private static func decodeValue(_ cursor: inout Cursor, depth: Int) -> xpc_object_t? {
        guard depth < maximumDepth, let raw = cursor.takeUInt8(), let tag = Tag(rawValue: raw) else {
            return nil
        }
        switch tag {
        case .uint64:
            guard let value = cursor.takeUInt64() else { return nil }
            return xpc_uint64_create(value)
        case .int64:
            guard let value = cursor.takeUInt64() else { return nil }
            return xpc_int64_create(Int64(bitPattern: value))
        case .bool:
            guard let value = cursor.takeUInt8() else { return nil }
            return xpc_bool_create(value != 0)
        case .string:
            guard let bytes = cursor.takeBytes() else { return nil }
            // `xpc_string_create` wants a C string; the wire carries no
            // terminator, so one is added here. A NUL inside is a lie about
            // the length and refused.
            guard !bytes.contains(0) else { return nil }
            var storage = [CChar](repeating: 0, count: bytes.count + 1)
            storage.withUnsafeMutableBytes { $0.copyBytes(from: bytes) }
            return xpc_string_create(storage)
        case .data:
            guard let bytes = cursor.takeBytes() else { return nil }
            return xpc_data_create(bytes.baseAddress, bytes.count)
        case .array:
            guard let count = cursor.takeUInt32(), Int(count) <= cursor.remaining else { return nil }
            let array = xpc_array_create(nil, 0)
            for _ in 0 ..< count {
                guard let value = decodeValue(&cursor, depth: depth + 1) else { return nil }
                xpc_array_append_value(array, value)
            }
            return array
        case .dictionary:
            guard let count = cursor.takeUInt32(), Int(count) <= cursor.remaining else { return nil }
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for _ in 0 ..< count {
                guard let keyBytes = cursor.takeBytes(), !keyBytes.contains(0),
                      let value = decodeValue(&cursor, depth: depth + 1)
                else { return nil }
                var key = [CChar](repeating: 0, count: keyBytes.count + 1)
                key.withUnsafeMutableBytes { $0.copyBytes(from: keyBytes) }
                xpc_dictionary_set_value(dictionary, key, value)
            }
            return dictionary
        }
    }
}
