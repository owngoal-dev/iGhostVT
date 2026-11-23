import Darwin
import Foundation

/// The MCP server's address as Settings hands it out: this device's
/// `.local` name, which every device on the local network resolves — this
/// one included — and which stays the same as its addresses change; its
/// address on the network when it has no such name; the loopback address
/// when it is on none.
enum MCPServerAddress {
    static var url: String {
        "http://\(host):\(MCPConsent.port)/mcp"
    }

    static var host: String {
        if let name = localHostName() {
            return name.lowercased() + ".local"
        }
        return RemoteNetwork.localIPv4() ?? "127.0.0.1"
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
