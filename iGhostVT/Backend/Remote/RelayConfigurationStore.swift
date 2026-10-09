import Foundation
import notify

/// The relay this device uses, at most one: the `.vtrpsc` file the user
/// imported, kept in the app's own container (0600, and on the device under
/// data protection until the first unlock, as `PairedRemoteHostStore` is).
/// It holds the relay's private key.
///
/// The app is the one truth about it. This device's helper keeps a copy to
/// register with while remote access is on; `RemoteAccessModel` compares the
/// helper's `relayFingerprint` with `fingerprint` on every status and sends
/// the file again (`setRelayConfiguration`) when they differ — a helper that
/// was not running when the file was imported or removed catches up the
/// next time anyone looks.
///
/// On the Mac, `ighostvt-cli remote relay` writes the same file as the same
/// user and posts `RelayConfiguration.storeChangedNotification`; the app
/// then forgets what it read and treats the file as freshly imported.
enum RelayConfigurationStore {
    static let didChange = Notification.Name("wiki.qaq.ighostvt.relayConfigurationDidChange")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: RelayConfiguration??

    static var current: RelayConfiguration? {
        lock.withLock {
            if let cache {
                return cache
            }
            let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? RelayConfiguration(data: $0) }
            cache = .some(loaded)
            return loaded
        }
    }

    /// What the helper should report when it uses the same relay; empty
    /// for none.
    static var fingerprint: String {
        current?.fingerprint ?? ""
    }

    static func save(_ configuration: RelayConfiguration) throws {
        let url = fileURL
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if targetEnvironment(macCatalyst)
                try configuration.encoded().write(to: url, options: .atomic)
            #else
                try configuration.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            chmod(url.path, 0o600)
            cache = .some(configuration)
        }
        AppLog.info(.transport, "relay is now \(configuration.name) at \(configuration.endpointDescription)")
        notify()
    }

    static func remove() {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
            cache = .some(nil)
        }
        AppLog.info(.transport, "relay removed")
        notify()
    }

    /// Reads the file again whenever the CLI says it rewrote it. The
    /// notification is unauthenticated — any process may post it — so it
    /// only makes the app read its own file, and goes further (asking the
    /// relay, syncing the helper) only when what the file holds changed:
    /// a flood of posts must not become a flood of relay requests.
    static func observeExternalChanges() {
        #if targetEnvironment(macCatalyst)
            var token: Int32 = 0
            notify_register_dispatch(RelayConfiguration.storeChangedNotification, &token, .main) { _ in
                let before = fingerprint
                lock.withLock { cache = nil }
                guard fingerprint != before else { return }
                AppLog.info(.transport, "relay configuration changed outside the app")
                notify()
            }
        #endif
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
            return base.appendingPathComponent(RelayConfiguration.macStoreSubpath)
        #else
            return base.appendingPathComponent("Relay.vtrpsc")
        #endif
    }

    private static func notify() {
        Task { @MainActor in
            NotificationCenter.default.post(name: didChange, object: nil)
            await RemoteHostDirectory.shared.refreshRelay(force: true)
            await RelayConfigurationSync.sync()
        }
    }
}

/// Brings this device's helper to the relay the app has.
@MainActor
enum RelayConfigurationSync {
    private static var isSending = false

    /// Asks for the helper's status and sends the configuration when it
    /// reports another one. A helper that is not running reports none at
    /// all and is left alone; it reads its own copy when it starts, and
    /// the next status after that settles it.
    static func sync() async {
        reconcile(with: await RemoteAccessControl.status())
    }

    /// The same, from a status already in hand.
    static func reconcile(with status: RemoteAccessStatus) {
        guard let reported = status.relayFingerprint, !isSending,
              reported != RelayConfigurationStore.fingerprint
        else { return }
        isSending = true
        Task {
            let data = RelayConfigurationStore.current?.encoded()
            _ = await RemoteAccessControl.setRelay(data)
            isSending = false
        }
    }
}
