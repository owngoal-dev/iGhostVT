import Darwin
import Network

/// Who a remote-access connection comes from.
enum RemoteNetwork {
    static func addressDescription(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        return hostDescription(host)
    }

    /// A host as an address string `NWEndpoint.Host` takes back. An IPv6
    /// address keeps no interface scope: a remembered link-local address
    /// would not name the same interface next time.
    static func hostDescription(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case let .name(name, _): return name
        @unknown default: return "\(host)"
        }
    }

    /// A host as a dotted IPv4 address, an IPv4-mapped IPv6 one included;
    /// nil for any other IPv6 address or a name.
    static func ipv4Description(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case let .ipv4(address):
            return "\(address)"
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16, bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF
            else { return nil }
            return bytes[12 ..< 16].map(String.init).joined(separator: ".")
        default:
            return nil
        }
    }

    /// Keeps a connection to a device on the local network on the local
    /// network: off every tunnel (`utun`, `ipsec` — a VPN, or a proxy app's
    /// packet tunnel) and off cellular, so it leaves by the Wi-Fi or
    /// Ethernet interface the other device is on. A proxy app in the way
    /// carries the link through a process of its own, and a device on this
    /// network is never reached better through one. A VM's bridge reads as
    /// wired Ethernet and stays allowed. Only a Bonjour service or a local
    /// address is narrowed, never the relay: that is on the internet, and
    /// a proxy may be the only way to it.
    static func keepOnLocalNetwork(_ parameters: NWParameters, to endpoint: NWEndpoint) {
        switch endpoint {
        case .service:
            break
        case .hostPort:
            guard isLocal(endpoint) else { return }
        default:
            return
        }
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
    }

    /// Until remote access goes beyond the local network, only a peer on it
    /// is served: private IPv4, link-local, loopback, IPv6 unique-local, and
    /// a global IPv6 address inside a prefix one of this device's own
    /// interfaces is on. That last one is the same link: Bonjour hands a
    /// device the global address as readily as the link-local one on a
    /// dual-stack network, and refusing it failed that connection outright
    /// — TCP had connected, so nothing tried the next address — and sent
    /// the link to the relay.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            return isLocal(ipv4: [UInt8](address.rawValue))
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isLocal(ipv4: Array(bytes[12 ..< 16]))
            }
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                return true
            }
            if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) {
                return true
            }
            return isOnLink(ipv6: bytes)
        default:
            return false
        }
    }

    /// This device's address on the local network, as the others reach it:
    /// the first private IPv4 of an interface that is up — Wi-Fi first.
    /// Advertised beside the host id, so a list can say which device a
    /// name is before anyone connects.
    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) }
            }
            guard isLocal(ipv4: bytes), bytes[0] != 127, !(bytes[0] == 169 && bytes[1] == 254) else { continue }
            found.append((String(cString: entry.ifa_name), bytes.map(String.init).joined(separator: ".")))
        }
        return (found.first { $0.name == "en0" } ?? found.first)?.address
    }

    /// Whether `bytes` lies in the prefix of an IPv6 address this device
    /// holds on a broadcast interface. A point-to-point interface (a VPN's
    /// tunnel) is not the local network, whatever prefix it was handed.
    private static func isOnLink(ipv6 bytes: [UInt8]) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return false }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6),
                  let netmask = entry.ifa_netmask
            else { continue }
            let own = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { [UInt8]($0) }
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { [UInt8]($0) }
            }
            // A link-local entry's prefix matches every link-local peer;
            // those were decided already, and it says nothing of a global one.
            guard own.count == 16, mask.count == 16, !(own[0] == 0xFE && own[1] & 0xC0 == 0x80),
                  mask.contains(where: { $0 != 0 })
            else { continue }
            if (0 ..< 16).allSatisfy({ own[$0] & mask[$0] == bytes[$0] & mask[$0] }) {
                return true
            }
        }
        return false
    }

    private static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }
}
