import Darwin
import Dispatch

/// On-disk mirror of the daemon's important events.
///
/// os_log from a jbroot daemon does not reliably reach `log`/idevicesyslog on
/// every bootstrap, and the daemon is exactly the process that needs a post-
/// mortem trail when the app can only say "connection lost". The file lives
/// in mobile's Logs so it is writable whether the daemon runs as root or as
/// mobile, and readable over ssh without elevation.
///
/// Both `ighostvtd` and `ighostvtd-io` write here; each line names its
/// process. No Foundation on purpose: the proxy lives under a 6 MB jetsam
/// limit and a `DateFormatter` alone drags ICU in.
///
/// The location is the protocol's (`iGhostVTProtocol.daemonLogPath`): the
/// app's log viewer reads this file, so the two must agree on where it is.
/// The line format is likewise read back by the app — keep
/// `LogReader.parseDaemonLine` in step with `log(_:)`.
enum DaemonFileLog {
    private static let path = iGhostVTProtocol.daemonLogPath
    private static let rotatedPath = iGhostVTProtocol.rotatedDaemonLogPath
    private static let rotateAtBytes = 512 * 1024
    private static let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.filelog",
        qos: .utility,
    )
    private static let processName = String(cString: getprogname())

    /// mobile's Library/Logs does not exist until someone makes it. `path` is
    /// always absolute, so everything before the last slash is its directory.
    private static let directoryReady: Void = makeDirectory(
        String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)]),
    )

    static func log(_ message: String) {
        let line = "\(timestamp()) [\(getpid()) \(processName)] \(message)\n"
        queue.async {
            _ = directoryReady
            let descriptor = openForAppend()
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { writeFully(descriptor, $0) }
        }
    }

    /// Waits for every line queued so far to reach the file. For the moment
    /// before an `exit`: libdispatch does not drain the queue for a dying
    /// process, and the line saying why it dies is the one worth having.
    static func flush() {
        queue.sync {}
    }

    private static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        let length = strftime(&buffer, buffer.count, "%m-%d %H:%M:%S", &parts)
        guard length > 0 else { return "?" }
        let millis = Int(now.tv_usec) / 1000
        let padding = millis < 10 ? "00" : millis < 100 ? "0" : ""
        return String(cString: buffer) + "." + padding + String(millis)
    }

    /// `mkdir -p`: every missing component, existing ones left alone.
    private static func makeDirectory(_ path: String) {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o755) != 0, errno != EEXIST {
                return
            }
        }
    }

    /// The log, open for appending and rotated first when it is over size.
    ///
    /// Off the control queue, so a forkpty can land while this is open:
    /// close-on-exec from the start (AGENTS.md, descriptors). Both
    /// processes rotate, so the size check runs under the file's lock and
    /// only for the inode the lock was taken on — a racer that waited out
    /// another's rename finds the path naming a fresh file and reopens it
    /// rather than renaming that fresh file over the history.
    private static func openForAppend() -> Int32 {
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC
        var descriptor = open(path, flags, 0o644)
        var attempts = 0
        while descriptor >= 0, attempts < 3 {
            attempts += 1
            _ = flock(descriptor, LOCK_EX)
            var held = stat()
            var named = stat()
            guard fstat(descriptor, &held) == 0, stat(path, &named) == 0 else { break }
            if held.st_ino == named.st_ino {
                guard held.st_size > rotateAtBytes else { break }
                _ = rename(path, rotatedPath)
            }
            close(descriptor)
            descriptor = open(path, flags, 0o644)
        }
        return descriptor
    }
}
