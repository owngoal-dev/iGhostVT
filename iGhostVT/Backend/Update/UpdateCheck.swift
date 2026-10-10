//
//  UpdateCheck.swift
//  iGhostVT
//

import CryptoKit
import Foundation
import UIKit

/// Check for Updates: asks GitHub for the latest release and, when it is
/// newer than this copy, downloads the one file of it that fits this
/// install. On a device that is the deb for this bootstrap — Settings ▸
/// Advanced, an alert with the progress and Cancel while it runs, then the
/// share sheet, which hands the package to a package manager before the APT
/// repository serves it. On the Mac the helper installs the update itself
/// (`HostUpdateFlow`, `MacUpdater`); only a copy that cannot update itself
/// gets the notarized zip in Downloads, shown in the Finder. Any other
/// answer is an alert. Nothing is installed or spawned by the app.
///
/// Files are found by their release asset names, the ones `Scripts/release.sh`
/// checks, and kept only when their bytes match the SHA-256 GitHub reports
/// for the asset.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(version: String, fraction: Double)
    }

    enum Outcome {
        case upToDate(version: String)
        /// The release is out but holds no file for this install — on the
        /// Mac, the Notarize run has not attached the zip yet.
        case notReady(version: String)
        case downloaded(file: URL)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle {
        didSet { showPhase() }
    }

    private var work: Task<Void, Never>?
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    /// The alert a check runs under on a device, and what it says.
    private var progressAlert: AlertViewController?
    private var progressContent: AlertViewController.Content?

    private nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/owngoal-dev/iGhostVT/releases/latest")!

    private init() {}

    /// Whether this install has a release file at all: a device needs a
    /// bootstrap the packages are built for.
    static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            packageArchitecture != nil
        #endif
    }

    /// Runs a check. `window` is where its alerts go; the Mac's menu item
    /// has none and uses the key window.
    ///
    /// On the Mac the helper does it (`HostUpdateFlow`): it checks, and on
    /// the person's word installs the notarized copy over this one and has
    /// the app relaunch. A copy that cannot update itself — ad-hoc signed,
    /// installed by an administrator — or a helper that does not answer
    /// falls back to the download below.
    func check(in window: UIWindow? = nil) {
        guard work == nil else { return }
        #if targetEnvironment(macCatalyst)
            guard !HostUpdateFlow.isRunning(.local) else { return }
            phase = .checking
            HostUpdateFlow.run(
                endpoint: .local,
                in: window ?? Self.keyWindow,
                unsupported: { [weak self] reason in
                    AppLog.info(.app, "update check: the helper does not install here (\(reason ?? "no answer")); downloading instead")
                    self?.download(in: window)
                },
                finished: { [weak self] in
                    if self?.work == nil {
                        self?.phase = .idle
                    }
                },
            )
        #else
            download(in: window)
        #endif
    }

    /// The download: the deb for this bootstrap on a device, the notarized
    /// zip in Downloads on a Mac that does not update itself.
    private func download(in window: UIWindow?) {
        guard work == nil else { return }
        #if !targetEnvironment(macCatalyst)
            let content = AlertViewController.Content(
                title: String(localized: "Checking for Updates…"),
                progress: .indeterminate,
            )
            let alert = AlertViewController(
                content: content,
                actions: [AlertAction("Cancel") { UpdateCheck.shared.cancel() }],
            )
            progressContent = content
            progressAlert = alert
            alert.present(in: window)
        #endif
        phase = .checking
        work = Task {
            let result: Outcome?
            do {
                result = try await run()
            } catch is CancellationError {
                result = nil
            } catch let error as URLError where error.code == .cancelled {
                result = nil
            } catch {
                AppLog.warning(.app, "update check: \(error.localizedDescription)")
                result = .failed(error.localizedDescription)
            }
            phase = .idle
            work = nil
            download = nil
            progressObservation = nil
            finish(with: result, in: window)
        }
    }

    /// The progress alert's Cancel, which is always there to press.
    func cancel() {
        work?.cancel()
        download?.cancel()
    }

    // MARK: - The check

    private func run() async throws -> Outcome {
        let installed = Self.installedVersion
        let release = try await Self.latestRelease()
        let latest = release.version
        AppLog.info(.app, "update check: latest \(release.tagName), installed \(installed)")
        guard Self.isVersion(latest, newerThan: installed) else {
            return .upToDate(version: installed)
        }
        guard let name = Self.assetName(for: latest),
              let asset = release.assets.first(where: { $0.name == name })
        else { return .notReady(version: latest) }
        guard let checksum = asset.sha256 else { throw UpdateCheckError.missingChecksum }

        let folder = try Self.destinationFolder()
        if let kept = await Self.existingCopy(named: name, in: folder, sha256: checksum) {
            return .downloaded(file: kept)
        }
        try Task.checkCancellation()
        phase = .downloading(version: latest, fraction: 0)
        let file = try await fetch(asset, sha256: checksum, into: folder, origin: release.page)
        AppLog.info(.app, "update check: saved \(file.lastPathComponent)")
        return .downloaded(file: file)
    }

    private func fetch(_ asset: Asset, sha256: String, into folder: URL, origin: URL?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let (task, observation) = Self.makeDownload(
                asset,
                sha256: sha256,
                into: folder,
                origin: origin,
                progress: { fraction in
                    Task { @MainActor in UpdateCheck.shared.noteProgress(fraction) }
                },
                completion: { continuation.resume(with: $0) },
            )
            download = task
            progressObservation = observation
            task.resume()
        }
    }

    /// At most one publish per percent: the observer fires per chunk.
    private func noteProgress(_ fraction: Double) {
        guard case let .downloading(version, shown) = phase else { return }
        let step = (fraction * 100).rounded(.down) / 100
        if step > shown {
            phase = .downloading(version: version, fraction: step)
        }
    }

    // MARK: - Showing it

    /// The application menu item's title on the Mac: the check's progress
    /// while one runs (`AppDelegate.validate`).
    var menuTitle: String {
        switch phase {
        case .idle:
            String(localized: "Check for Updates… (menu)")
        case .checking:
            String(localized: "Checking for Updates…")
        case let .downloading(_, fraction):
            String(localized: "Downloading Update… \(Self.percent(fraction))")
        }
    }

    private func showPhase() {
        guard let progressContent, case let .downloading(version, fraction) = phase else { return }
        progressContent.title = String(localized: "Downloading iGhostVT \(version)")
        progressContent.message = Self.percent(fraction)
        progressContent.progress = .fraction(fraction)
    }

    private static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The progress alert goes first — then a download goes straight to
    /// the share sheet (the Finder on the Mac), and any other answer into
    /// an alert of its own. Cancelled, nothing follows.
    private func finish(with outcome: Outcome?, in window: UIWindow?) {
        let alert = progressAlert
        progressAlert = nil
        progressContent = nil
        let next = {
            guard let outcome else { return }
            if case let .downloaded(file) = outcome {
                #if targetEnvironment(macCatalyst)
                    Self.reveal(file)
                #else
                    ShareSheet.present(file, in: window)
                #endif
                return
            }
            Self.alert(for: outcome).present(in: window ?? Self.keyWindow)
        }
        if let alert {
            alert.close(then: next)
        } else {
            next()
        }
    }

    private static func alert(for outcome: Outcome) -> AlertViewController {
        let done = [AlertAction("Done", kind: .highlighted)]
        switch outcome {
        case let .upToDate(version):
            return AlertViewController(
                title: "No Update Available",
                message: "iGhostVT \(version) is the latest version.",
                actions: done,
            )
        case let .notReady(version):
            #if targetEnvironment(macCatalyst)
                return AlertViewController(
                    title: "Update Not Ready",
                    message: "iGhostVT \(version) is out, but its notarized Mac download is not ready yet. Try again in a few minutes.",
                    actions: done,
                )
            #else
                return AlertViewController(
                    title: "Update Not Ready",
                    message: "iGhostVT \(version) is out, but it has no package for this jailbreak.",
                    actions: done,
                )
            #endif
        case let .failed(reason):
            return AlertViewController(
                title: "Unable to Check for Updates",
                message: "\(reason)",
                actions: done,
            )
        case .downloaded:
            preconditionFailure("a download is shown, never asked about")
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Built off the main actor on purpose: URLSession calls the completion,
    /// and KVO the observer, on threads of their own, and a closure formed in
    /// a main-actor method traps there under Swift 6's isolation checks.
    private nonisolated static func makeDownload(
        _ asset: Asset,
        sha256: String,
        into folder: URL,
        origin: URL?,
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void,
    ) -> (URLSessionDownloadTask, NSKeyValueObservation) {
        let source = asset.browserDownloadURL
        let task = URLSession.shared.downloadTask(with: source) { location, response, error in
            // The file at `location` is removed once this returns, so it is
            // checked and moved here.
            completion(Result {
                if let error {
                    throw error
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let location, status == 200 else { throw UpdateCheckError.unexpectedResponse(status) }
                guard try checksum(of: location) == sha256 else { throw UpdateCheckError.checksumMismatch }
                return try place(location, named: asset.name, in: folder, source: source, origin: origin)
            })
        }
        let observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value.fractionCompleted)
        }
        return (task, observation)
    }

    // MARK: - GitHub

    private struct Release: Decodable {
        let tagName: String
        let page: URL?
        let assets: [Asset]

        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case page = "html_url"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        /// GitHub's own digest of the uploaded bytes, `sha256:<hex>`.
        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            return digest.dropFirst("sha256:".count).lowercased()
        }

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    private nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try JSONDecoder().decode(Release.self, from: data)
        case 403 where http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", 429:
            throw UpdateCheckError.rateLimited
        case let status:
            throw UpdateCheckError.unexpectedResponse(status)
        }
    }

    // MARK: - Versions

    private nonisolated static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `x.y.z` against `x.y.z`, number by number; anything else is not newer.
    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
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

    // MARK: - The file

    private nonisolated static func assetName(for version: String) -> String? {
        #if targetEnvironment(macCatalyst)
            "iGhostVT-\(version)-macos-notarized.zip"
        #else
            packageArchitecture.map { "wiki.qaq.ighostvt_\(version)_\($0).deb" }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
        /// The package this install came from, read off where the app sits:
        /// under rootless the bundle is inside the directory `/var/jb`
        /// resolves to (usually through a symlink, so canonical against
        /// canonical, as `RuntimeEnvironment` compares them); under roothide
        /// it is in a jbroot's `Applications`. Nil anywhere else — the
        /// Simulator, a development install — where no package fits. Debug
        /// builds take `UpdateCheck.packageArchitecture` from the defaults.
        nonisolated static var packageArchitecture: String? {
            #if DEBUG
                if let forced = UserDefaults.standard.string(forKey: "UpdateCheck.packageArchitecture") {
                    return forced
                }
            #endif
            guard let bundle = canonicalPath(Bundle.main.bundlePath) else { return nil }
            if let bootstrap = canonicalPath("/var/jb"), bundle.hasPrefix(bootstrap + "/") {
                return "iphoneos-arm64"
            }
            let folder = (bundle as NSString).deletingLastPathComponent
            if (folder as NSString).lastPathComponent == "Applications", folder != "/Applications" {
                return "iphoneos-arm64e"
            }
            return nil
        }

        private nonisolated static func canonicalPath(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    #endif

    /// Downloads on the Mac, where the person looks for a download. A
    /// folder of the app's own on a device, emptied before each file: the
    /// share sheet hands the package on, and nothing reads it after.
    private nonisolated static func destinationFolder() throws -> URL {
        #if targetEnvironment(macCatalyst)
            try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        #else
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        #endif
    }

    /// The file a check before this one left, when its bytes are still the
    /// release's — asking twice downloads once.
    private nonisolated static func existingCopy(named name: String, in folder: URL, sha256: String) async -> URL? {
        let file = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return await Task.detached { (try? checksum(of: file)) == sha256 ? file : nil }.value
    }

    private nonisolated static func checksum(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Never over a file of the person's on the Mac: a name already taken
    /// gets the Finder's " 2". On a device the folder is the app's own.
    private nonisolated static func place(
        _ location: URL,
        named name: String,
        in folder: URL,
        source: URL,
        origin: URL?,
    ) throws -> URL {
        let fileManager = FileManager.default
        var destination = folder.appendingPathComponent(name)
        #if targetEnvironment(macCatalyst)
            let stem = (name as NSString).deletingPathExtension
            let suffix = (name as NSString).pathExtension
            var copy = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(stem) \(copy).\(suffix)")
                copy += 1
            }
        #else
            for old in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: old)
            }
        #endif
        try fileManager.moveItem(at: location, to: destination)
        #if targetEnvironment(macCatalyst)
            quarantine(destination, source: source, origin: origin)
        #endif
        return destination
    }

    #if targetEnvironment(macCatalyst)
        /// Marked the way a browser marks a download, so the app inside goes
        /// through Gatekeeper on its first open — for this zip, the
        /// notarization check. The key is spelled out because
        /// `NSURLQuarantinePropertiesKey` is marked unavailable on iOS and
        /// Catalyst inherits that, though the Foundation underneath is the
        /// Mac's and honours it.
        private nonisolated static func quarantine(_ file: URL, source: URL, origin: URL?) {
            var properties: [String: Any] = [
                "LSQuarantineAgentName": "iGhostVT",
                "LSQuarantineType": "LSQuarantineTypeWebDownload",
                "LSQuarantineDataURL": source,
            ]
            properties["LSQuarantineOriginURL"] = origin
            do {
                try (file as NSURL).setResourceValue(properties, forKey: URLResourceKey(rawValue: "NSURLQuarantinePropertiesKey"))
            } catch {
                AppLog.warning(.app, "update check: quarantine: \(error.localizedDescription)")
            }
        }

        /// The file selected in a Finder window. NSWorkspace is AppKit's, so
        /// it is reached through the runtime, as `MacLaunchAgent` does.
        static func reveal(_ file: URL) {
            guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
                  let workspace = workspaceClass
                  .perform(NSSelectorFromString("sharedWorkspace"))?
                  .takeUnretainedValue() as? NSObject
            else {
                UIApplication.shared.open(file.deletingLastPathComponent())
                return
            }
            workspace.perform(NSSelectorFromString("activateFileViewerSelectingURLs:"), with: [file] as NSArray)
        }
    #endif
}

private enum UpdateCheckError: LocalizedError {
    case unexpectedResponse(Int)
    case rateLimited
    case missingChecksum
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case let .unexpectedResponse(status):
            String(localized: "GitHub answered with an unexpected response (\(status)).")
        case .rateLimited:
            String(localized: "GitHub is limiting requests from this network. Try again later.")
        case .missingChecksum:
            String(localized: "GitHub reports no checksum for the download, so it was not kept.")
        case .checksumMismatch:
            String(localized: "The download did not match the checksum GitHub reports for it, so it was not kept.")
        }
    }
}
