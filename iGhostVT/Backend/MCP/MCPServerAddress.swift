import Darwin
import Foundation

/// The MCP server's addresses as Settings hands them out: the loopback
/// address, for an app on this device, and the one other devices use —
/// this device's `.local` name, which every device on the local network
/// resolves and which stays the same as its addresses change, or its
/// address on the network when it has no such name. A device on no
/// network has only the first.
enum MCPServerAddress {
    static var all: [String] {
        [url(host: "127.0.0.1")] + (networkHost().map { [url(host: $0)] } ?? [])
    }

    private static func url(host: String) -> String {
        "http://\(host):\(MCPConsent.port)/mcp"
    }

    private static func networkHost() -> String? {
        if let name = localHostName() {
            return name.lowercased() + ".local"
        }
        return RemoteNetwork.localIPv4()
    }

    /// The Bonjour name (System Settings' Local hostname), from configd.
    /// Reached by name: SystemConfiguration's header keeps it to macOS,
    /// and Catalyst follows the iOS header, though the function is in the
    /// library on both.
    private static func localHostName() -> String? {
        typealias CopyLocalHostName = @convention(c) (UnsafeRawPointer?) -> Unmanaged<CFString>?
        guard let library = dlopen(
            "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
            RTLD_LAZY,
        ),
            let symbol = dlsym(library, "SCDynamicStoreCopyLocalHostName")
        else { return nil }
        let copy = unsafeBitCast(symbol, to: CopyLocalHostName.self)
        guard let name = copy(nil)?.takeRetainedValue() as String?, !name.isEmpty else {
            return nil
        }
        return name
    }
}
