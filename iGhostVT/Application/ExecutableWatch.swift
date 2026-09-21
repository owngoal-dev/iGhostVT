import Foundation

/// Tells a running app that its executable was replaced or removed.
///
/// dpkg installs each file by renaming the new copy over the old one, so the
/// executable this process was launched from loses its last name while the
/// process runs on: old code, against a new daemon and new resources. kqueue
/// reports the name going (a suspended app hears it on resume), and the link
/// count says it was the last name rather than dpkg's `.dpkg-tmp` backup.
///
/// The app asks the person to relaunch rather than quitting under them: a
/// screen may hold unsaved work. Daemons are not watched. The package's
/// postinst restarts the daemon once every file is in place, and one that
/// stopped the moment its binary was replaced would stop mid-unpack, taking
/// down whatever it was running for the old app.
///
/// One copy per app, identical to platformize-app-ios's
/// `template/App/ExecutableWatch.swift`.
enum ExecutableWatch {
    /// Calls `replaced` once, on the main queue.
    static func start(_ replaced: @escaping () -> Void) {
        guard let path = Bundle.main.executablePath else { return }
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.delete, .link], queue: .main)
        // The handler holds the source, so the watch outlives this call;
        // cancelling releases both.
        let check = {
            guard !source.isCancelled else { return }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_nlink == 0 else { return }
            source.cancel()
            replaced()
        }
        source.setEventHandler(handler: check)
        // Unlink may happen between open() and kernel registration. Check once
        // registration completes as well as on subsequent filesystem events.
        source.setRegistrationHandler(handler: check)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
}
