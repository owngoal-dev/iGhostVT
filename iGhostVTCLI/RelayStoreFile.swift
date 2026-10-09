import Darwin
import Foundation
import notify

/// The Mac app's own copy of the relay configuration
/// (`RelayConfigurationStore`), which this program reads and writes as the
/// same user the app runs as. The app is the one truth about the relay: a
/// configuration handed to the helper alone would be taken back the next
/// time the app compared the two, so `remote relay` changes the app's file
/// and then brings the helper to it, exactly as an import in Settings does.
///
/// Mac only. On the device the app has no container and keeps the file
/// under a home this program cannot name reliably — and it may be running
/// as root, which never writes into mobile's directories by path.
enum RelayStoreFile {
    /// A `.vtrpsc` file is a few hundred bytes; anything far past that is
    /// not one.
    private static let maximumFileByteCount = 64 * 1024

    #if os(macOS)
        static var path: String {
            // The account's home, not `$HOME`: under `sudo -u` the
            // environment may still name the caller's.
            let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
                ?? NSHomeDirectory()
            return home + "/Library/Application Support/" + RelayConfiguration.macStoreSubpath
        }
    #endif

    /// Reads and checks a configuration the user named. Its content never
    /// reaches a message: it holds the relay's private key.
    static func read(from path: String) throws -> RelayConfiguration {
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumFileByteCount, let data = try? Data(contentsOf: url) else {
            throw CLIError.usage("Unable to read \(path).")
        }
        do {
            return try RelayConfiguration(data: data)
        } catch let error as RelayConfiguration.ParseError {
            throw CLIError.usage(error.errorDescription ?? "This file is not an iGhostVT relay configuration.")
        }
    }

    #if os(macOS)
        /// The configuration the app has; nil for none, or for a file it
        /// would not read either.
        static func load() -> RelayConfiguration? {
            guard let data = FileManager.default.contents(atPath: path),
                  data.count <= maximumFileByteCount
            else { return nil }
            return try? RelayConfiguration(data: data)
        }

        /// Replaces the app's file. Written 0600 from the first byte — a
        /// temporary file made by `mkstemp`, then renamed over the old one —
        /// so the key is never readable by anyone else, not even briefly.
        static func save(_ configuration: RelayConfiguration) throws {
            let directory = (path as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700],
                )
            } catch {
                throw CLIError.relayStoreFailed(directory)
            }
            var template = Array((directory + "/.Relay.XXXXXX").utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw CLIError.relayStoreFailed(directory) }
            let temporary = String(cString: template)
            let data = configuration.encoded()
            let written = data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return fsync(descriptor) == 0
            }
            close(descriptor)
            // `rename` replaces a symlink left at the name rather than
            // following it.
            guard written, rename(temporary, path) == 0 else {
                unlink(temporary)
                throw CLIError.relayStoreFailed(path)
            }
            announce()
        }

        static func remove() throws {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw CLIError.relayStoreFailed(path)
            }
            announce()
        }

        /// Tells a running app to read the file again.
        private static func announce() {
            notify_post(RelayConfiguration.storeChangedNotification)
        }
    #endif
}
