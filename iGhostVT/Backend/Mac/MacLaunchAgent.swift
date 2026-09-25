//
//  MacLaunchAgent.swift
//  iGhostVT
//

import Combine
import CryptoKit
import Foundation

#if targetEnvironment(macCatalyst)
    import ServiceManagement
#endif

/// The distributed Mac build's half of the daemon boundary.
///
/// On the device `ighostvtd` is a LaunchDaemon the .deb installed and the app
/// only ever connects to it. On macOS there is no package manager, so the
/// helper ships *inside* the app bundle — `Contents/MacOS/ighostvtd`, launched
/// by `Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist` — and the app
/// registers it with `SMAppService` on first launch. The user approves it once
/// in Login Items, and from then on the agent moves, updates, and is deleted
/// with the app.
///
/// This type exists on every platform so call sites need no `#if`. Off
/// Catalyst it reports `.notApplicable`, which reads as "nothing to gate on".
@MainActor
final class MacLaunchAgent: ObservableObject {
    static let shared = MacLaunchAgent()

    enum Status: Equatable {
        /// iOS and iPadOS: the .deb installed the daemon, there is nothing to
        /// register.
        case notApplicable
        /// macOS 12, where `SMAppService` does not exist. Nothing to offer;
        /// treated as ready so the ordinary connection error still surfaces
        /// rather than being masked by a control that cannot help.
        case unsupported
        /// Launched from the download, or Gatekeeper-translocated. Registering
        /// now would bind Login Items to a path that vanishes when the app
        /// quits, so the app offers to move itself to /Applications first
        /// (`moveToApplications()`).
        case needsRelocation
        /// Nothing is registered: either this is a first launch that has not
        /// got there yet, or the helper was turned off in Settings.
        case notRegistered
        /// Registered, but a person still has to allow it in Login Items.
        case needsApproval
        /// The helper in the bundle is not the one Login Items holds — an
        /// update replaced it — and the registration is being redone. Ends
        /// in `.enabled` once the new helper has answered, or `.failed`.
        case rebinding
        case enabled
        /// The bundle has no helper plist to register. A packaging fault —
        /// or a copy someone took apart — that no control in the app can
        /// mend; the only way on is a fresh download.
        case brokenInstallation
        case failed(String)
    }

    @Published private(set) var status: Status

    /// Where a whole copy of the app comes from, for the broken-install card.
    static let downloadPageURL = URL(string: "https://github.com/owngoal-dev/iGhostVT/releases")!

    /// Whether sessions may be opened. `unsupported` counts: it means this
    /// type has no opinion, not that the daemon is missing.
    var isReady: Bool {
        switch status {
        case .notApplicable, .unsupported, .enabled: true
        case .needsRelocation, .notRegistered, .needsApproval, .rebinding, .brokenInstallation, .failed: false
        }
    }

    /// The rebind in flight, if any. While it runs, `refresh()` must not
    /// overwrite `status` with what `SMAppService` says — a stale item reads
    /// `.enabled` — and a second `activate()` must not start another.
    private var rebindTask: Task<Void, Never>?

    private init() {
        #if targetEnvironment(macCatalyst)
            status = .unsupported
            refresh()
            // Every launch registers: the plain register is idempotent and
            // bootstraps the job when launchd has none, and `activate()` is
            // where a replaced helper is caught (see `helperDigest`) — the
            // case where Login Items still says "enabled" but nothing can
            // run. Someone who turned the item off in System Settings keeps
            // it off; a register does not override that.
            if status == .enabled || status == .notRegistered {
                activate()
            }
        #else
            status = .notApplicable
        #endif
    }

    #if targetEnvironment(macCatalyst)

        /// Must match the file `Scripts/package-mac.sh` stages into
        /// `Contents/Library/LaunchAgents`.
        private static let plistName = "wiki.qaq.ighostvtd.plist"

        /// Re-reads the agent's state. Observes only — it never registers, so
        /// it is safe to call from `sceneDidBecomeActive` (where a change made
        /// in System Settings while the app was in the background gets
        /// noticed) without undoing a person's decision to turn the helper off.
        func refresh() {
            guard #available(macCatalyst 16.0, *) else {
                status = .unsupported
                return
            }
            guard rebindTask == nil else { return }
            guard Self.isInApplications else {
                status = .needsRelocation
                return
            }
            let service = SMAppService.agent(plistName: Self.plistName)
            switch service.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .needsApproval
            case .notRegistered:
                status = .notRegistered
            case .notFound:
                // Apple's name is broader than a missing file: after
                // `launchctl bootout` of an SMAppService job — what the zip
                // update does, and what a replaced-bundle repair does — BTM
                // has no item and this is the status that comes back even
                // though the plist is still in the bundle. Treat that as
                // unregistered so `activate()` runs. Only a bundle that
                // actually has no helper is a packaging fault.
                status = Self.bundledHelperIsPresent ? .notRegistered : .brokenInstallation
            @unknown default:
                status = .needsApproval
            }
        }

        /// Registers the bundled agent. Called on every launch, and from the
        /// cards that name a helper that is not running.
        ///
        /// A registration is not just a plist: Background Task Management
        /// keeps a *launch constraint* for the item, and for an ad-hoc signed
        /// helper (no Team ID) that constraint pins the exact binary. After an
        /// update replaces the bundle, `register()` alone is worse than
        /// useless — BTM reuses the existing item, launchd submits the job,
        /// AMFI kills the new helper on the spot ("Launch Constraint
        /// Violation"), launchd drops the service, and BTM's own repair ten
        /// seconds later leaves a job whose program is the unresolved relative
        /// `Contents/MacOS/ighostvtd`, retried every ten seconds forever. A
        /// relaunch finds that item and changes nothing. Only unregistering
        /// discards the item, so that is what happens (`rebind`) whenever the
        /// helper in the bundle is not the one this app registered last time.
        func activate() {
            guard #available(macCatalyst 16.0, *) else { return }
            guard rebindTask == nil else { return }
            guard Self.isInApplications else {
                status = .needsRelocation
                return
            }
            let service = SMAppService.agent(plistName: Self.plistName)
            let digest = Self.helperDigest
            if service.status != .notRegistered, digest != Self.registeredHelperDigest {
                status = .rebinding
                rebindTask = Task { await rebind(service, helperDigest: digest) }
                return
            }
            register(service, helperDigest: digest)
        }

        /// How many unregister → register → answer rounds a rebind gets
        /// before it reports failure. The second round is the one that
        /// binds the fresh item launchd's repair made after the first.
        private static let rebindRounds = 3

        /// How long after a `register()` launchd's repair of a failed spawn
        /// has certainly run. A spawn that dies to a launch constraint is
        /// pushed out by ten seconds ("Service only ran for 0 seconds"), and
        /// that deferred spawn is where the item is invalidated. Two seconds
        /// of margin.
        private static let repairWindow: TimeInterval = 12

        /// The SDK header says an updated executable must be re-registered,
        /// "and it is recommended to also call unregister before
        /// re-registering". What it does not say, read off the unified log
        /// of a real ad-hoc update (`smd`, `backgroundtaskmanagementd`,
        /// `launchd`, 2026-09-02):
        ///
        /// - `unregister()` does not remove the Background Task Management
        ///   item. It sets it *disabled*, and the `register()` that follows
        ///   logs `found existing item` and re-enables that same item — with
        ///   the launch constraint it recorded for the *old* helper. So an
        ///   unregister → register on its own can never mend a stale
        ///   constraint, however long it waits in between.
        /// - What does produce a fresh item is launchd. The re-enabled job
        ///   spawns, AMFI kills the new helper, and launchd schedules a
        ///   "repair LWCR update" spawn ten seconds out; that spawn has BTM
        ///   `invalidateLaunchItem` the old item and make a new one. For an
        ///   ad-hoc helper the repair then fails in place ("executable
        ///   doesn't have a Team ID", `Unable to update LWCR with smd: 22`)
        ///   and the job is left inactive with the unresolved relative
        ///   program — but an unregister → register *after* that point binds
        ///   the fresh item to the helper on disk, and it runs.
        /// - A second round fired *before* the repair cancels the throttled
        ///   spawn ("canceling throttled spawn") and re-enables the stale
        ///   item once more, forever. So a failed round is followed by a
        ///   wait past `repairWindow` before the next one.
        /// - The unregister's completion fires after the kill; the status is
        ///   polled until it stops reading registered; the register is
        ///   retried through BTM's settling window, in which it is refused.
        /// - `status` reads `.enabled` throughout, so it proves nothing. The
        ///   one test that means anything is a round trip to the helper, and
        ///   the digest is recorded only once that succeeds: a rebind that
        ///   did not take is retried on the next launch, not remembered as
        ///   done.
        @available(macCatalyst 16.0, *)
        private func rebind(_ service: SMAppService, helperDigest digest: String?) async {
            defer { rebindTask = nil }
            var registeredAt: Date?
            for round in 1 ... Self.rebindRounds {
                if let registeredAt {
                    let remaining = Self.repairWindow - Date().timeIntervalSince(registeredAt)
                    if remaining > 0 {
                        AppLog.info(
                            .app,
                            "launch agent: waiting \(Int(remaining.rounded(.up))) s for launchd's repair of the item",
                        )
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
                AppLog.info(
                    .app,
                    "launch agent: rebinding the helper, round \(round), status \(service.status.rawValue)",
                )
                do {
                    try await service.unregister()
                } catch {
                    // A `.notFound` item — what `launchctl bootout` leaves —
                    // has nothing to unregister; the register still goes on.
                    AppLog.info(.app, "launch agent: unregister: \(error.localizedDescription)")
                }
                await Self.awaitUnregistered(service)
                registeredAt = Date()
                guard await Self.registerThroughSettling(service) else {
                    AppLog.warning(.app, "launch agent: register refused after unregister")
                    continue
                }
                if service.status == .requiresApproval {
                    // Nothing can answer until a person allows it; the item
                    // is this helper's, so the record is right.
                    Self.registeredHelperDigest = digest
                    status = .needsApproval
                    return
                }
                if await Self.helperAnswers() {
                    Self.registeredHelperDigest = digest
                    status = .enabled
                    AppLog.info(.app, "launch agent: helper answered after rebind")
                    return
                }
                AppLog.warning(
                    .app,
                    "launch agent: helper did not answer after rebind, status \(service.status.rawValue)",
                )
            }
            status = .failed(Self.registrationFailure)
        }

        /// Waits for BTM to stop reporting the item, up to five seconds.
        @available(macCatalyst 16.0, *)
        private static func awaitUnregistered(_ service: SMAppService) async {
            for _ in 0 ..< 20 {
                if service.status == .notRegistered || service.status == .notFound {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        /// Registers, retrying through the settling window in which BTM
        /// refuses it (500 ms × 12, comfortably past what has been seen).
        /// True once the item is registered — approval pending counts.
        @available(macCatalyst 16.0, *)
        private static func registerThroughSettling(_ service: SMAppService) async -> Bool {
            for _ in 0 ..< 12 {
                do {
                    try service.register()
                    return true
                } catch {
                    if service.status == .enabled || service.status == .requiresApproval {
                        return true
                    }
                    AppLog.info(.app, "launch agent: register: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return false
        }

        /// Whether the registered helper actually runs: a `hello` and a
        /// `listSessions` over a connection of their own. The connection
        /// demand-launches the job, so a helper AMFI kills on spawn answers
        /// with an error, and an item launchd dropped with none at all.
        private static func helperAnswers() async -> Bool {
            await withCheckedContinuation { continuation in
                XPCDaemonTransport.listSessions(timeout: 6) { rows in
                    continuation.resume(returning: rows != nil)
                }
            }
        }

        private static var registrationFailure: String {
            String(
                localized: "Unable to turn on Terminal Helper. Try again.",
                comment: "Mac agent error when registering the LaunchAgent fails",
            )
        }

        /// Opens System Settings on Login Items, for the approval step.
        func openLoginItemsSettings() {
            guard #available(macCatalyst 16.0, *) else { return }
            SMAppService.openSystemSettingsLoginItems()
        }

        /// Moves this bundle into the Applications folder and reopens it from
        /// there — what LetsMove does for AppKit apps, possible here because
        /// the Mac build is not sandboxed.
        ///
        /// The bundle that moves is the *original*: a quarantined download
        /// runs from Gatekeeper's read-only translocation mount, and
        /// `Bundle.main` names the mount, not the file in Downloads. A move
        /// (a rename on the same volume) is tried first and a copy stands in
        /// when the source is read-only, a mounted disk image say. The
        /// quarantine flag comes off the result, or the copy would be
        /// translocated again on its first launch and land right back here.
        /// The relaunch goes through LaunchServices — `NSWorkspace`, reached
        /// through the runtime — with `createsNewApplicationInstance`, since
        /// a plain open would only activate this instance; this one exits
        /// once the new one is on its way. Nothing was connected yet (the
        /// status gates every session), so nothing is lost.
        func moveToApplications() {
            let source = Self.originalBundleURL
            let folder = Self.applicationsFolder
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let fileManager = FileManager.default
            // A bundle a shell `mv` put in Applications keeps the quarantine's
            // translocate bit, so it still runs from the mount and reads as
            // relocatable while the original already sits at the destination.
            // Trashing "what is there" would then delete the app itself; the
            // quarantine flag is all that needs to go.
            if source.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path {
                Self.removeQuarantine(at: source)
                Self.relaunch(from: source)
                return
            }
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.trashItem(at: destination, resultingItemURL: nil)
                }
                do {
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    try fileManager.copyItem(at: source, to: destination)
                    try? fileManager.trashItem(at: source, resultingItemURL: nil)
                }
                Self.removeQuarantine(at: destination)
            } catch {
                status = .failed(
                    String(
                        localized: "Unable to move iGhostVT to Applications. Move it there in Finder, then open it again.",
                        comment: "Mac agent error when moving the app bundle fails",
                    ),
                )
                return
            }
            Self.relaunch(from: destination)
        }

        /// The folder the app belongs in: `/Applications`, or the user's own
        /// when the system one is not writable (a managed Mac).
        private static var applicationsFolder: URL {
            let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if FileManager.default.isWritableFile(atPath: system.path) {
                return system
            }
            let home = homeDirectory ?? NSHomeDirectory()
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true)
        }

        /// The bundle on disk, seen through Gatekeeper's translocation when
        /// there is one. `SecTranslocateCreateOriginalPathForURL` is not in
        /// the Catalyst SDK, so it is looked up in Security by hand.
        private static var originalBundleURL: URL {
            let bundle = Bundle.main.bundleURL
            typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
            guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
                  let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
            else { return bundle }
            let original = unsafeBitCast(symbol, to: Original.self)
            guard let url = original(bundle as CFURL, nil)?.takeRetainedValue() else { return bundle }
            return url as URL
        }

        private static func removeQuarantine(at url: URL) {
            let name = "com.apple.quarantine"
            removexattr(url.path, name, XATTR_NOFOLLOW)
            guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
            for case let item as URL in items {
                removexattr(item.path, name, XATTR_NOFOLLOW)
            }
        }

        /// The relocation alert's other answer. Through AppKit, so
        /// `applicationWillTerminate` runs as it would for ⌘Q.
        func quit() {
            AppTermination.terminate()
        }

        private static func relaunch(from url: URL) {
            guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
                  let workspace = workspaceClass
                  .perform(NSSelectorFromString("sharedWorkspace"))?
                  .takeUnretainedValue() as? NSObject,
                  let configurationClass = NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type,
                  let configuration = configurationClass
                  .perform(NSSelectorFromString("configuration"))?
                  .takeUnretainedValue() as? NSObject
            else { return }
            configuration.setValue(true, forKey: "createsNewApplicationInstance")
            let selector = NSSelectorFromString("openApplicationAtURL:configuration:completionHandler:")
            guard workspace.responds(to: selector) else { return }
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, AnyObject, AnyObject?) -> Void
            let open = unsafeBitCast(workspace.method(for: selector), to: Open.self)
            let completion: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in
                DispatchQueue.main.async { exit(0) }
            }
            open(workspace, selector, url as NSURL, configuration, unsafeBitCast(completion, to: AnyObject.self))
            // In case LaunchServices never calls back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }

        /// SHA-256 of the helper binary in this bundle, or nil when there is
        /// none. Content, not version: a locally cut zip can carry the same
        /// version as the one it replaces and still be a different signature.
        private static var helperDigest: String? {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ighostvtd")
            guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// The files `SMAppService.agent(plistName:)` and `BundleProgram` need.
        /// `.notFound` is not this check — see `refresh()`.
        private static var bundledHelperIsPresent: Bool {
            let root = Bundle.main.bundleURL
            let plist = root.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
            return FileManager.default.isReadableFile(atPath: plist.path) && helperDigest != nil
        }

        /// The digest of the helper whose registration was last seen to hold
        /// — recorded by a plain `register()`, and by a rebind only once the
        /// helper answered. Absent on installs older than this check, which
        /// reads as "unknown" and rebinds once — the state an update from
        /// such a version leaves behind is exactly the one this exists to
        /// repair.
        private static let registeredHelperDigestKey = "MacLaunchAgent.registeredHelperDigest"
        private static var registeredHelperDigest: String? {
            get { UserDefaults.standard.string(forKey: registeredHelperDigestKey) }
            set { UserDefaults.standard.set(newValue, forKey: registeredHelperDigestKey) }
        }

        /// The plain register: a first launch, or the helper turned back on.
        /// No old item stands in the way here, so the digest is recorded as
        /// soon as the item exists.
        @available(macCatalyst 16.0, *)
        private func register(_ service: SMAppService, helperDigest: String?) {
            do {
                try service.register()
            } catch {
                // A registration that fails because approval is pending is not
                // an error worth showing; the status re-read below tells the
                // truth either way.
                if service.status != .requiresApproval, service.status != .enabled {
                    AppLog.warning(.app, "launch agent: register: \(error.localizedDescription)")
                    status = .failed(Self.registrationFailure)
                    return
                }
            }
            Self.registeredHelperDigest = helperDigest
            switch service.status {
            case .enabled: status = .enabled
            default: status = .needsApproval
            }
        }

        /// Login Items binds to the path the app was registered from. From a
        /// download that path is either inside the quarantine's read-only
        /// translocation mount or a folder the user will empty, and either way
        /// the entry is dangling by the second launch — so registration waits
        /// until the app lives somewhere permanent.
        private static var isInApplications: Bool {
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/Applications/") {
                return true
            }
            guard let home = Self.homeDirectory else { return false }
            return path.hasPrefix("\(home)/Applications/")
        }

        /// The real home directory. Not `homeDirectoryForCurrentUser`, which
        /// Catalyst marks unavailable, and not `NSHomeDirectory()`, which
        /// answers the app's container when sandboxed — this build is not, but
        /// a path check has no business depending on that staying true.
        private static var homeDirectory: String? {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
                return nil
            }
            return URL(fileURLWithPath: String(cString: directory))
                .resolvingSymlinksInPath().path
        }

    #else

        func refresh() {}
        func activate() {}
        func openLoginItemsSettings() {}
        func moveToApplications() {}
        func quit() {}

    #endif
}
