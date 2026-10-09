import CryptoKit
import Foundation
import Network

/// A relay, as the `.vtrpsc` file its server writes describes it: where it
/// is, which relay it is, and the private key that makes a device one of
/// its members (`Relay/PROTOCOL.md`). The key is a secret — whoever holds
/// the file may register hosts there and list them — and it never leaves
/// the device: the relay keeps only the public half and checks signatures.
struct RelayConfiguration: Equatable, Sendable {
    static let format = "ighostvt-relay"
    /// The file format's version, not the protocol's
    /// (`RelayControl.protocolVersion`).
    static let formatVersion = 1
    static let fileExtension = "vtrpsc"
    static let typeIdentifier = "wiki.qaq.ighostvt.relay-config"
    static let defaultPort: UInt16 = 46405
    /// Where the Mac app keeps its copy, under the user's Application
    /// Support. `ighostvt-cli remote relay` writes the same file, as the
    /// same user, so the app stays the one truth about which relay is used.
    static let macStoreSubpath = "iGhostVT/Relay.vtrpsc"
    /// Posted (`notify_post`) after something other than the app rewrote
    /// that file. It carries nothing and grants nothing — whoever posts it
    /// only makes the app read its own file again.
    static let storeChangedNotification = "wiki.qaq.ighostvt.relay-configuration"

    enum ParseError: LocalizedError {
        case notConfiguration
        case unsupportedVersion
        case invalid

        var errorDescription: String? {
            switch self {
            case .notConfiguration:
                String(localized: "This file is not an iGhostVT relay configuration.")
            case .unsupportedVersion:
                String(localized: "This relay configuration needs a newer version of iGhostVT.")
            case .invalid:
                String(localized: "This relay configuration is damaged.")
            }
        }
    }

    var name: String
    /// A name or an address, an IPv6 one without brackets.
    var host: String
    var port: UInt16
    var relayID: String
    /// The raw 32-byte P-256 scalar.
    var key: Data

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == Self.format
        else { throw ParseError.notConfiguration }
        guard (object["version"] as? Int) == Self.formatVersion else { throw ParseError.unsupportedVersion }
        guard let endpoint = object["endpoint"] as? String,
              let (host, port) = Self.split(endpoint: endpoint),
              let relayID = object["relayID"] as? String, Self.isValidRelayID(relayID),
              let encodedKey = object["key"] as? String,
              let key = Data(base64Encoded: encodedKey),
              (try? P256.Signing.PrivateKey(rawRepresentation: key)) != nil
        else { throw ParseError.invalid }
        let name = (object["name"] as? String).map(RemoteAccess.sanitizedName) ?? relayID
        self.name = name
        self.host = host
        self.port = port
        self.relayID = relayID
        self.key = key
    }

    /// The file's content, as the server writes it.
    func encoded() -> Data {
        let object: [String: Any] = [
            "format": Self.format,
            "version": Self.formatVersion,
            "name": name,
            "endpoint": endpointDescription,
            "relayID": relayID,
            "key": key.base64EncodedString(),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// `host:port`, an IPv6 address bracketed.
    var endpointDescription: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    var signingKey: P256.Signing.PrivateKey {
        // Checked when the file was read.
        try! P256.Signing.PrivateKey(rawRepresentation: key)
    }

    /// Which relay, and which key: equal for two copies of the same file,
    /// different once the server rotates its key or moves. What the app and
    /// the helper compare to know they use the same one; carries nothing
    /// secret.
    var fingerprint: String {
        let digest = SHA256.hash(data: signingKey.publicKey.derRepresentation)
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(relayID)/\(prefix)@\(endpointDescription)"
    }

    private static func split(endpoint: String) -> (String, UInt16)? {
        let host: Substring
        let portText: Substring?
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            host = endpoint[endpoint.index(after: endpoint.startIndex) ..< close]
            let rest = endpoint[endpoint.index(after: close)...]
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else {
            let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            portText = parts.count == 2 ? parts[1] : nil
        }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "/" })
        else { return nil }
        guard let portText else { return (String(host), defaultPort) }
        guard let port = UInt16(portText), port != 0 else { return nil }
        return (String(host), port)
    }

    private static func isValidRelayID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }
}
