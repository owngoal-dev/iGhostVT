import Darwin
import Dispatch
import Foundation
import notify
#if os(macOS)
    import CryptoKit
    import MachO
    import Security
#endif

/// The Mac's own update (`iGhostVTOperation.hostUpdate`): the menu's Check
/// for Updates…, `ighostvt-cli update` and a paired device's Check for
/// Update all end here.
///
/// It lives in `ighostvtd-io` because putting a new copy in place takes
/// processes — `ditto` to unpack the zip, `xattr` to clear what the
/// download left on it, `open` for an app that is not running — and the
/// app spawns none and the proxy only its two children. Every step runs on
/// a queue of its own, never the control queue a session's bytes go
/// through; clients see it only by asking.
///
/// What is put in place is the release's notarized zip and nothing else,
/// and only when every bit of it checks out: the bytes match the SHA-256
/// GitHub reports for the asset, the bundle is `wiki.qaq.iGhostVT` at the
/// release's version, its signature (and each helper's) is valid, a
/// Developer ID one, notarized, and names the Team ID the installed copy
/// carries — the same rule Background Task Management and TCC key their
/// grants on, so nothing the person allowed is lost in the swap. A copy
/// with no Team ID (ad-hoc, a local build) has no team to match and is
/// `unsupported`, as is one not in `/Applications` or one this user does
/// not own (an administrator's install), which this user cannot replace.
///
/// The swap is one `renamex_np(RENAME_SWAP)` inside `/Applications`, so the
/// bundle is never missing or half-written. The app then relaunches — told
/// by `iGhostVTProtocol.updateInstalledNotification`, or opened if it was
/// not running — and its launch-agent rebind restarts this helper from the
/// new bundle, which ends every session on the Mac.
final class MacUpdater: @unchecked Sendable {
    struct Snapshot {
        var state: HostUpdateState
        var installedVersion: String
        var latestVersion: String?
        var progress: Double?
        var message: String?
    }

    private let lock = NSLock()
    private var snapshot: Snapshot
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.io.update", qos: .utility)

    init() {
        #if os(macOS)
            snapshot = Snapshot(state: .idle, installedVersion: Self.installedVersion ?? "0")
            queue.async { Self.sweepLeftovers() }
        #else
            snapshot = Snapshot(state: .idle, installedVersion: "0")
        #endif
    }

    /// While a step runs the idle `shutdown` is refused: an exit would cut
    /// a download, or a swap, in half.
    var isBusy: Bool {
        lock.withLock { snapshot.state.isBusy }
    }

    /// Starts what the request asks for, unless something is already under
    /// way, and answers where things stand. Never blocks. An install asked
    /// for while a check runs is kept for when the check finds one; a
    /// cancel stops a check or a download, and an install before the swap.
    func request(check: Bool, install: Bool, cancel: Bool) -> Snapshot {
        lock.withLock {
            #if os(macOS)
                if cancel {
                    if snapshot.state.isBusy, snapshot.state != .installing {
                        isCancelled = true
                        installAfterCheck = false
                        download?.cancel()
                    }
                    return snapshot
                }
                if snapshot.state == .checking, install {
                    installAfterCheck = true
                    return snapshot
                }
                guard !snapshot.state.isBusy, snapshot.state != .installed else { return snapshot }
                if install, snapshot.state == .available, let release {
                    begin(.downloading, latest: release.version)
                    queue.async { self.install(release) }
                } else if install || check {
                    begin(.checking, latest: snapshot.latestVersion)
                    installAfterCheck = install
                    queue.async { self.check() }
                }
            #else
                if install || check {
                    snapshot.state = .unsupported
                    snapshot.message = "A device updates iGhostVT through its package manager."
                }
            #endif
            return snapshot
        }
    }

    /// Under `lock`.
    private func begin(_ state: HostUpdateState, latest: String?) {
        snapshot.state = state
        snapshot.latestVersion = latest
        snapshot.progress = state == .downloading ? 0 : nil
        snapshot.message = nil
        #if os(macOS)
            isCancelled = false
        #endif
    }

    private func set(_ state: HostUpdateState, latest: String? = nil, progress: Double? = nil, message: String? = nil) {
        lock.withLock {
            snapshot.state = state
            if let latest {
                snapshot.latestVersion = latest
            }
            snapshot.progress = progress
            snapshot.message = message
        }
        if let message {
            DaemonFileLog.log("update: \(state.rawValue): \(message)")
        } else {
            DaemonFileLog.log("update: \(state.rawValue)\(latest.map { " \($0)" } ?? "")")
        }
    }

    #if os(macOS)

        static let destination = "/Applications/iGhostVT.app"
        private static let bundleIdentifier = "wiki.qaq.iGhostVT"
        private static let appExecutable = "Contents/MacOS/iGhostVT"
        /// Where a new copy waits beside the old one before the swap; the
        /// process id ends the name.
        private static let incomingPrefix = ".iGhostVT.app.update-"
        /// Every program in `Contents/MacOS` besides the app: each is
        /// checked against the team on its own, since the bundle's seal
        /// covers their bytes but not who signed them.
        private static let helperExecutables = ["ighostvtd", "ighostvtd-io", "ighostvtd-remote", "ighostvt-cli"]
        private static let latestReleaseURL = URL(string: "https://api.github.com/repos/owngoal-dev/iGhostVT/releases/latest")!

        private struct Release: Decodable {
            let tagName: String
            let assets: [Asset]

            var version: String {
                tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            }

            var asset: Asset? {
                assets.first { $0.name == "iGhostVT-\(version)-macos-notarized.zip" }
            }

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }

        private struct Asset: Decodable {
            let name: String
            let url: URL
            let digest: String?

            var sha256: String? {
                guard let digest, digest.hasPrefix("sha256:") else { return nil }
                return digest.dropFirst("sha256:".count).lowercased()
            }

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
                case digest
            }
        }

        /// Read and written under `lock`.
        /// What the last check found.
        private var release: Release?
        /// An install was asked for while the check ran.
        private var installAfterCheck = false
        /// A cancel came in; the running step stops at its next turn.
        private var isCancelled = false
        private var download: URLSessionDownloadTask?

        private struct Failure: Error {
            let message: String
            init(_ message: String) {
                self.message = message
            }
        }

        private struct Cancelled: Error {}

        private func checkCancelled() throws {
            if lock.withLock({ isCancelled }) {
                throw Cancelled()
            }
        }

        // MARK: - The installed copy

        /// The bundle this program runs from: `…/iGhostVT.app`, three
        /// levels above `Contents/MacOS/ighostvtd-io`, canonical.
        private static var bundlePath: String? {
            var size = UInt32(MAXPATHLEN)
            var raw = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&raw, &size) == 0, let resolved = realpath(raw, nil) else { return nil }
            defer { free(resolved) }
            let executable = URL(fileURLWithPath: String(cString: resolved))
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return bundle.pathExtension == "app" ? bundle.path : nil
        }

        private static var installedVersion: String? {
            guard let bundlePath,
                  let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")
            else { return nil }
            return info["CFBundleShortVersionString"] as? String
        }

        /// The Team ID the update has to carry, or why this copy cannot
        /// update itself.
        private static func installedTeam() -> Result<String, Failure> {
            guard let bundle = bundlePath, bundle == destination else {
                return .failure(Failure("iGhostVT updates itself only when it is in the Applications folder."))
            }
            var status = stat()
            guard lstat(bundle, &status) == 0, status.st_uid == getuid(),
                  access("/Applications", W_OK) == 0, access(bundle, W_OK) == 0
            else {
                return .failure(Failure("This copy of iGhostVT was installed by an administrator, so it cannot replace itself. Install the update the same way."))
            }
            guard let team = teamIdentifier(of: bundle) else {
                return .failure(Failure("This copy of iGhostVT has no Developer ID signature, so it does not update itself. Download the update from GitHub."))
            }
            return .success(team)
        }

        private static func teamIdentifier(of path: String) -> String? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
                  let code
            else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let information = information as? [String: Any]
            else { return nil }
            return information[kSecCodeInfoTeamIdentifier as String] as? String
        }

        /// A copy an interrupted install left beside the bundle — one of
        /// this user's, never another's. LaunchServices would otherwise know
        /// two iGhostVTs, and might open the stray one.
        private static func sweepLeftovers() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") else { return }
            for name in names where name.hasPrefix(incomingPrefix) {
                let path = "/Applications/" + name
                var status = stat()
                guard lstat(path, &status) == 0, status.st_uid == getuid() else { continue }
                do {
                    try FileManager.default.removeItem(atPath: path)
                    DaemonFileLog.log("update: removed \(path), left by an earlier install")
                } catch {
                    DaemonFileLog.log("update: could not remove \(path): \(error.localizedDescription)")
                }
            }
        }

        // MARK: - Check

        private func check() {
            let team = Self.installedTeam()
            guard case .success = team else {
                if case let .failure(failure) = team {
                    set(.unsupported, message: failure.message)
                }
                return
            }
            let found: Release
            do {
                found = try Self.latestRelease()
                try checkCancelled()
            } catch is Cancelled {
                return settleCancelled(latest: nil)
            } catch let failure as Failure {
                return set(.failed, message: failure.message)
            } catch {
                return set(.failed, message: error.localizedDescription)
            }
            let installed = Self.installedVersion ?? "0"
            lock.withLock { snapshot.installedVersion = installed }
            guard Self.isVersion(found.version, newerThan: installed) else {
                lock.withLock { release = nil }
                return set(.upToDate, latest: found.version)
            }
            guard found.asset?.sha256 != nil else {
                lock.withLock { release = nil }
                return set(.failed, latest: found.version, message: "iGhostVT \(found.version) is out, but its notarized Mac download is not ready yet. Try again in a few minutes.")
            }
            let thenInstall = lock.withLock { () -> Bool in
                release = found
                defer { installAfterCheck = false }
                return installAfterCheck
            }
            if thenInstall {
                set(.downloading, latest: found.version, progress: 0)
                install(found)
            } else {
                set(.available, latest: found.version)
            }
        }

        /// GitHub's latest release, or the one `IGHOSTVT_UPDATE_FEED` names
        /// — an https or file URL of a document of the same shape, which is
        /// how the update is tested against a build that is not released.
        /// Whatever it names is held to every check below; it only chooses
        /// where to look.
        private static func latestRelease() throws -> Release {
            var source = latestReleaseURL
            if let feed = ProcessInfo.processInfo.environment["IGHOSTVT_UPDATE_FEED"], !feed.isEmpty {
                guard let url = URL(string: feed), isAllowedSource(url) else {
                    throw Failure("IGHOSTVT_UPDATE_FEED is not an https or file URL.")
                }
                source = url
            }
            var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try Self.load(request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? (source.isFileURL ? 200 : 0) {
            case 200:
                guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    throw Failure("GitHub's answer about the latest release could not be read.")
                }
                guard release.asset.map({ isAllowedSource($0.url) }) ?? true else {
                    throw Failure("The release's download is not an https or file URL.")
                }
                return release
            case 403 where http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", 429:
                throw Failure("GitHub is limiting requests from this network. Try again later.")
            case let status:
                throw Failure("GitHub answered with an unexpected response (\(status)).")
            }
        }

        private static func isAllowedSource(_ url: URL) -> Bool {
            url.scheme == "https" || url.isFileURL
        }

        private static func load(_ request: URLRequest) throws -> (Data, URLResponse?) {
            let done = DispatchSemaphore(value: 0)
            let box = ResultBox<(Data, URLResponse?)>()
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    box.result = .failure(error)
                } else {
                    box.result = .success((data ?? Data(), response))
                }
                done.signal()
            }.resume()
            done.wait()
            return try box.result?.get() ?? { throw Failure("No answer.") }()
        }

        /// `x.y.z` against `x.y.z`, number by number; anything else is not
        /// newer. The app's `UpdateCheck.isVersion` says the same.
        static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
            func numbers(_ version: String) -> [Int]? {
                let parts = version.split(separator: ".").map { Int($0) }
                guard !parts.isEmpty, !parts.contains(nil) else { return nil }
                return parts.compactMap(\.self)
            }
            guard let lhs = numbers(candidate), let rhs = numbers(installed) else { return false }
            for index in 0 ..< max(lhs.count, rhs.count) {
                let left = index < lhs.count ? lhs[index] : 0
                let right = index < rhs.count ? rhs[index] : 0
                if left != right {
                    return left > right
                }
            }
            return false
        }

        // MARK: - Install

        private func install(_ release: Release) {
            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ighostvt-update-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                let team = try Self.installedTeam().get()
                guard let asset = release.asset, let sha256 = asset.sha256 else {
                    throw Failure("The release has no notarized Mac download.")
                }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let zip = try download(asset, sha256: sha256, into: staging)
                try checkCancelled()

                set(.verifying, latest: release.version)
                let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], log: staging)
                let app = unpacked.appendingPathComponent("iGhostVT.app", isDirectory: true)
                try Self.clearAttributes(app, log: staging)
                try Self.verify(app.path, team: team, version: release.version)
                try checkCancelled()

                try swapIn(app, team: team, version: release.version, log: staging)
            } catch is Cancelled {
                settleCancelled(latest: release.version)
            } catch let failure as Failure {
                set(.failed, latest: release.version, message: failure.message)
            } catch let error as URLError where error.code == .cancelled {
                settleCancelled(latest: release.version)
            } catch {
                set(.failed, latest: release.version, message: error.localizedDescription)
            }
        }

        /// Back to what the last check found, as though nothing was asked.
        private func settleCancelled(latest: String?) {
            let hasRelease = lock.withLock { () -> Bool in
                isCancelled = false
                return release != nil
            }
            DaemonFileLog.log("update: cancelled")
            set(hasRelease ? .available : .idle, latest: latest)
        }

        private func download(_ asset: Asset, sha256: String, into folder: URL) throws -> URL {
            let destination = folder.appendingPathComponent(asset.name)
            let done = DispatchSemaphore(value: 0)
            let box = ResultBox<Void>()
            var request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                defer { done.signal() }
                // The file at `location` is gone once this returns.
                box.result = Result {
                    if let error {
                        throw error
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? (asset.url.isFileURL ? 200 : 0)
                    guard let location, status == 200 else {
                        throw Failure("GitHub answered with an unexpected response (\(status)).")
                    }
                    try FileManager.default.moveItem(at: location, to: destination)
                }
            }
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let step = (progress.fractionCompleted * 100).rounded(.down) / 100
                self?.noteProgress(step)
            }
            let isCancelled = lock.withLock { () -> Bool in
                download = task
                return self.isCancelled
            }
            if isCancelled {
                task.cancel()
            }
            task.resume()
            done.wait()
            observation.invalidate()
            lock.withLock { download = nil }
            try box.result?.get()
            guard try Self.checksum(of: destination) == sha256 else {
                throw Failure("The download did not match the checksum GitHub reports for it, so it was not installed.")
            }
            return destination
        }

        private func noteProgress(_ step: Double) {
            lock.withLock {
                guard snapshot.state == .downloading, step > (snapshot.progress ?? 0) else { return }
                snapshot.progress = step
            }
        }

        private static func checksum(of file: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// `xattr -cr`: the quarantine flag and anything else the download
        /// and the unpack left behind. A flag left on the bundle has
        /// Gatekeeper translocate the next launch, which then registers the
        /// helper from a mount that is gone by the launch after.
        private static func clearAttributes(_ bundle: URL, log: URL) throws {
            try run("/usr/bin/xattr", ["-cr", bundle.path], log: log)
        }

        /// The release's copy, held to everything the installed one is
        /// trusted for. `notarized` is the ticket the zip carries stapled,
        /// or Apple's answer for it.
        private static func verify(_ path: String, team: String, version: String) throws {
            var status = stat()
            guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
                throw Failure("The download holds no iGhostVT.app.")
            }
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                  info["CFBundleIdentifier"] as? String == bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == version
            else {
                throw Failure("The download is not iGhostVT \(version).")
            }
            let developerID = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
            try validate(path, requirement: "\(developerID) and identifier \"\(bundleIdentifier)\" and notarized", team: team)
            for helper in helperExecutables {
                let helperPath = path + "/Contents/MacOS/" + helper
                guard access(helperPath, X_OK) == 0 else {
                    throw Failure("The download is missing \(helper).")
                }
                try validate(helperPath, requirement: developerID, team: team)
            }
        }

        private static func validate(_ path: String, requirement text: String, team: String) throws {
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
            else {
                throw Failure("The download's signature could not be read.")
            }
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            var error: Unmanaged<CFError>?
            let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
            guard status == errSecSuccess else {
                let reason = error?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
                DaemonFileLog.log("update: \(path) failed its check: \(reason)")
                let signer = teamIdentifier(of: path)
                if signer != team {
                    throw Failure("The download is signed by \(signer.map { "team \($0)" } ?? "no Developer ID"), not by the team that signed this copy (\(team)), so it was not installed.")
                }
                throw Failure("The download's signature is not valid, so it was not installed.")
            }
        }

        /// The new copy is put beside the old one inside `/Applications` —
        /// same volume, so the swap is a rename — checked again where it
        /// landed, and swapped in at once. `installed` is said the moment
        /// the rename is done: the app's relaunch restarts this process
        /// soon after, and a client asking then must hear how it ended.
        private func swapIn(_ app: URL, team: String, version: String, log: URL) throws {
            let incoming = "/Applications/" + Self.incomingPrefix + String(getpid())
            try? FileManager.default.removeItem(atPath: incoming)
            try Self.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noqtn", app.path, incoming], log: log)
            do {
                try Self.clearAttributes(URL(fileURLWithPath: incoming), log: log)
                try Self.verify(incoming, team: team, version: version)
                try checkCancelled()
            } catch {
                try? FileManager.default.removeItem(atPath: incoming)
                throw error
            }
            set(.installing, latest: version)
            let appWasRunning = Self.isAppRunning()
            guard renamex_np(incoming, Self.destination, UInt32(RENAME_SWAP)) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(atPath: incoming)
                throw Failure("The new copy could not be put in place: \(reason).")
            }
            set(.installed, latest: version)
            DaemonFileLog.log("update: iGhostVT \(version) is in place; the app \(appWasRunning ? "is told to relaunch" : "is opened")")
            // Before the old copy goes: the app hears this first, and its
            // executable losing its last name then reads as the relaunch
            // already under way, not as an update to ask about.
            notify_post(iGhostVTProtocol.updateInstalledNotification)
            if !appWasRunning {
                // In the background, as the open-at-login agent opens it:
                // the launch is for the helper's rebind, not for a window.
                try? Self.run("/usr/bin/open", ["-g", Self.destination], log: log)
            }
            // `incoming` now names the old copy. Should the relaunch end
            // this process first, the next start sweeps it.
            do {
                try FileManager.default.removeItem(atPath: incoming)
            } catch {
                DaemonFileLog.log("update: the old copy stays at \(incoming): \(error.localizedDescription)")
            }
        }

        /// Whether this user runs the app from `/Applications` now.
        private static func isAppRunning() -> Bool {
            let target = destination + "/" + appExecutable
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return false }
            var pids = [pid_t](repeating: 0, count: Int(count) + 32)
            let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
                var info = proc_bsdshortinfo()
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                      info.pbsi_uid == getuid(),
                      proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
                else { continue }
                if String(cString: buffer) == target {
                    return true
                }
            }
            return false
        }

        /// Runs a system tool to completion, its output in a file under
        /// `log` (a pipe could fill and stall it), its own descriptors only.
        /// io reaps only the shells it knows by pid, so this `waitpid` is
        /// the only one that sees the tool.
        private static func run(_ tool: String, _ arguments: [String], log: URL) throws {
            let output = log.appendingPathComponent("tool.log").path
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Never a session's PTY or the proxy's socket.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv: [UnsafeMutablePointer<CChar>?] = ([tool] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, tool, &actions, &attributes, argv, environ)
            guard spawned == 0 else {
                throw Failure("\((tool as NSString).lastPathComponent) could not start: \(String(cString: strerror(spawned))).")
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            let exited = (status & 0x7F) == 0
            let code = (status >> 8) & 0xFF
            guard exited, code == 0 else {
                let said = (try? String(contentsOfFile: output, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DaemonFileLog.log("update: \(tool) \(arguments.joined(separator: " ")) failed (\(status)): \(said)")
                throw Failure("\((tool as NSString).lastPathComponent) failed\(said.isEmpty ? "" : ": \(said)")")
            }
        }

    #endif
}

#if os(macOS)
    /// A completion handler's answer, handed to the thread waiting on it.
    /// The semaphore orders the write before the read.
    private final class ResultBox<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }
#endif
