import Darwin
import Foundation
import XPC

/// `ighostvt-cli update [--check]`: the Mac's own update, the one the
/// application menu's Check for Updates… and a paired device's Update Host
/// run (`hostUpdate`, carried out by `ighostvtd-io`). The daemon does the
/// work; this asks for it and reports until it settles.
enum UpdateCommand {
    /// A check is a round trip to GitHub; a download is the zip.
    private static let deadline: TimeInterval = 15 * 60

    static func run(checkOnly: Bool) throws {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        var reply = try client.request(.hostUpdate) {
            xpc_dictionary_set_bool($0, checkOnly ? iGhostVTWireKey.updateCheck : iGhostVTWireKey.updateInstall, true)
        }
        var shown = ""
        var latest = "?"
        let installed = DaemonClient.string(reply, iGhostVTWireKey.appVersion)
        var state = HostUpdateState.idle
        let end = Date().addingTimeInterval(deadline)
        while true {
            state = HostUpdateState(rawValue: DaemonClient.string(reply, iGhostVTWireKey.updateState) ?? "") ?? .failed
            latest = DaemonClient.string(reply, iGhostVTWireKey.updateVersion) ?? latest
            let line = describe(state, reply)
            if line != shown {
                print(line)
                fflush(stdout)
                shown = line
            }
            var again: ((xpc_object_t) -> Void)?
            switch state {
            case .failed, .unsupported:
                exit(1)
            case .available where checkOnly, .upToDate, .installed:
                return
            case .available:
                // Found by a check someone else ran: ask for the install.
                again = { xpc_dictionary_set_bool($0, iGhostVTWireKey.updateInstall, true) }
            default:
                break
            }
            guard Date() < end else { throw CLIError.timedOut }
            usleep(500_000)
            do {
                reply = try client.request(.hostUpdate, again ?? { _ in })
            } catch {
                // Past the swap the app relaunches and the helper restarts
                // under this connection: that is the install finishing. A
                // local feed can get there between two polls, so the bundle
                // on disk decides, never the last state seen.
                guard !checkOnly, let installed, let onDisk = bundleVersionOnDisk(), onDisk != installed else {
                    throw error
                }
                latest = onDisk
                print("iGhostVT \(latest) is installed. iGhostVT relaunches and its terminal helper restarts, which ends every session on this Mac.")
                return
            }
        }
    }

    /// The version of the bundle this CLI sits in, read from disk: after
    /// the swap that is the new one.
    private static func bundleVersionOnDisk() -> String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let info = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: info.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static func describe(_ state: HostUpdateState, _ reply: xpc_object_t) -> String {
        let installed = DaemonClient.string(reply, iGhostVTWireKey.appVersion) ?? "?"
        let latest = DaemonClient.string(reply, iGhostVTWireKey.updateVersion) ?? "?"
        let message = DaemonClient.string(reply, iGhostVTWireKey.errorMessage)
        switch state {
        case .unsupported: return message ?? "This iGhostVT does not update itself."
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "iGhostVT \(installed) is the latest version."
        case .available: return "iGhostVT \(latest) is available (installed: \(installed)). Run `ighostvt-cli update` to install it."
        case .downloading:
            let progress = xpc_dictionary_get_double(reply, iGhostVTWireKey.updateProgress)
            return "Downloading iGhostVT \(latest)… \(Int((progress * 100).rounded(.down)))%"
        case .verifying: return "Checking the signature of iGhostVT \(latest)…"
        case .installing: return "Installing iGhostVT \(latest)…"
        case .installed: return "iGhostVT \(latest) is installed. iGhostVT relaunches and its terminal helper restarts, which ends every session on this Mac."
        case .failed: return message ?? "The update failed."
        }
    }
}
