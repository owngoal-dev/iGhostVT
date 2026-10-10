//
//  HostUpdate.swift
//  iGhostVT
//

import UIKit
import XPC

/// Where a Mac's own update stands, as its `ighostvtd-io` reports it
/// (`iGhostVTOperation.hostUpdate`).
struct HostUpdateStatus: Sendable {
    var state: HostUpdateState
    var installedVersion: String
    var latestVersion: String?
    var progress: Double?
    var message: String?
}

/// One `hostUpdate` over a link of its own — this Mac's daemon, or a paired
/// device's — and the answer. The daemon never waits on the work, so every
/// ask is short; a client follows a check or an install by asking again.
enum HostUpdateClient {
    static func ask(
        at endpoint: DaemonEndpoint,
        check: Bool = false,
        install: Bool = false,
        cancel: Bool = false,
        timeout: TimeInterval = 15,
    ) async -> HostUpdateStatus? {
        await withCheckedContinuation { continuation in
            ask(at: endpoint, check: check, install: install, cancel: cancel, timeout: timeout) {
                continuation.resume(returning: $0)
            }
        }
    }

    private static func ask(
        at endpoint: DaemonEndpoint,
        check: Bool,
        install: Bool,
        cancel: Bool,
        timeout: TimeInterval,
        completion: @escaping @Sendable (HostUpdateStatus?) -> Void,
    ) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.update", qos: .userInitiated)
        let finished = AnswerOnce(completion)
        guard let connection = endpoint.makeLink(queue: queue) else {
            finished.finish(nil)
            return
        }
        connection.activate { event in
            if case .lost = event, finished.finish(nil) {
                connection.cancel()
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if finished.finish(nil) {
                connection.cancel()
            }
        }
        connection.send(XPCDaemonTransport.makeMessage(.hello)) { reply in
            guard XPCDaemonTransport.replyCode(of: reply) == .success else {
                // Another release line: say so, rather than "no answer".
                var refusal: HostUpdateStatus?
                if XPCDaemonTransport.replyCode(of: reply) == .unsupportedVersion,
                   case let .remote(hostID) = endpoint
                {
                    let theirs = xpc_dictionary_get_string(reply, iGhostVTWireKey.appVersion).map { String(cString: $0) } ?? ""
                    let name = PairedRemoteHostStore.host(id: hostID)?.displayName
                    refusal = HostUpdateStatus(
                        state: .unsupported,
                        installedVersion: theirs,
                        message: RemoteVersionText.mismatch(theirs: theirs, name: name),
                    )
                }
                if finished.finish(refusal) {
                    connection.cancel()
                }
                return
            }
            let request = XPCDaemonTransport.makeMessage(.hostUpdate)
            if check {
                xpc_dictionary_set_bool(request, iGhostVTWireKey.updateCheck, true)
            }
            if install {
                xpc_dictionary_set_bool(request, iGhostVTWireKey.updateInstall, true)
            }
            if cancel {
                xpc_dictionary_set_bool(request, iGhostVTWireKey.updateCancel, true)
            }
            connection.send(request) { reply in
                connection.cancel()
                finished.finish(status(in: reply))
            }
        }
    }

    private static func status(in reply: xpc_object_t) -> HostUpdateStatus? {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              XPCDaemonTransport.replyCode(of: reply) == .success,
              let state = string(iGhostVTWireKey.updateState, in: reply).flatMap(HostUpdateState.init(rawValue:))
        else { return nil }
        return HostUpdateStatus(
            state: state,
            installedVersion: string(iGhostVTWireKey.appVersion, in: reply) ?? "",
            latestVersion: string(iGhostVTWireKey.updateVersion, in: reply),
            progress: xpc_dictionary_get_value(reply, iGhostVTWireKey.updateProgress)
                .map { xpc_double_get_value($0) },
            message: string(iGhostVTWireKey.errorMessage, in: reply),
        )
    }

    private static func string(_ key: String, in reply: xpc_object_t) -> String? {
        xpc_dictionary_get_string(reply, key).map { String(cString: $0) }
    }
}

/// The reply, the link's loss and the timeout race; the first one answers.
private final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (HostUpdateStatus?) -> Void)?

    init(_ completion: @escaping @Sendable (HostUpdateStatus?) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ value: HostUpdateStatus?) -> Bool {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return false }
        completion(value)
        return true
    }
}

/// Check for Updates for a Mac — this one from the menu, a paired one from
/// Settings — as alerts: what the check found, a confirmation before
/// anything is replaced, the download's progress, and how it ended. The Mac
/// does the work (`MacUpdater`); this only asks and shows.
@MainActor
final class HostUpdateFlow {
    /// The run in flight, by endpoint: asking again joins nothing, it is
    /// refused while one is up.
    private static var running: Set<String> = []

    private let endpoint: DaemonEndpoint
    private let hostName: String?
    private weak var window: UIWindow?
    private let unsupported: ((String?) -> Void)?
    private let finished: () -> Void
    private var alert: AlertViewController?
    private var content: AlertViewController.Content?
    private var isCancelled = false

    /// `unsupported` takes over when the Mac cannot update itself (the
    /// menu falls back to downloading the zip); without it, that is said
    /// in an alert. `finished` runs once, however it ends.
    static func run(
        endpoint: DaemonEndpoint,
        in window: UIWindow?,
        unsupported: ((String?) -> Void)? = nil,
        finished: @escaping () -> Void = {},
    ) {
        let key = Self.key(endpoint)
        guard !running.contains(key) else { return }
        running.insert(key)
        var name: String?
        if case let .remote(hostID) = endpoint {
            name = PairedRemoteHostStore.host(id: hostID)?.displayName
        }
        let flow = HostUpdateFlow(endpoint: endpoint, hostName: name, window: window, unsupported: unsupported) {
            running.remove(key)
            finished()
        }
        Task { await flow.start() }
    }

    static func isRunning(_ endpoint: DaemonEndpoint) -> Bool {
        running.contains(key(endpoint))
    }

    private static func key(_ endpoint: DaemonEndpoint) -> String {
        switch endpoint {
        case .local: "local"
        case let .remote(hostID): hostID
        }
    }

    private init(
        endpoint: DaemonEndpoint,
        hostName: String?,
        window: UIWindow?,
        unsupported: ((String?) -> Void)?,
        finished: @escaping () -> Void,
    ) {
        self.endpoint = endpoint
        self.hostName = hostName
        self.window = window
        self.unsupported = unsupported
        self.finished = finished
    }

    private var isRemote: Bool {
        endpoint.isRemote
    }

    private var displayName: String {
        hostName ?? String(localized: "the other device")
    }

    // MARK: - Steps

    private func start() async {
        showProgress(String(localized: "Checking for Updates…"), progress: .indeterminate)
        let status = await follow(HostUpdateClient.ask(at: endpoint, check: true))
        guard !isCancelled else { return end() }
        guard let status else {
            return conclude(
                title: String(localized: "Unable to Check for Updates"),
                message: isRemote
                    ? String(localized: "\(displayName) did not answer. Check that it is on and try again.")
                    : String(localized: "The terminal helper did not answer."),
                orUnsupported: true,
            )
        }
        switch status.state {
        case .unsupported:
            conclude(title: String(localized: "Updates Not Available"), message: status.message ?? "", orUnsupported: true)
        case .upToDate:
            conclude(
                title: String(localized: "No Update Available"),
                message: isRemote
                    ? String(localized: "\(displayName) runs iGhostVT \(status.installedVersion), the latest version.")
                    : String(localized: "iGhostVT \(status.installedVersion) is the latest version."),
            )
        case .available:
            closeProgress { self.confirm(status) }
        case .installed:
            closeProgress { self.showInstalled(version: status.latestVersion ?? "") }
        default:
            conclude(
                title: String(localized: "Unable to Check for Updates"),
                message: status.message ?? String(localized: "Unable to complete this action. Try again."),
            )
        }
    }

    private func confirm(_ status: HostUpdateStatus) {
        let version = status.latestVersion ?? ""
        let message = isRemote
            ? String(localized: "\(displayName) runs iGhostVT \(status.installedVersion). It downloads the notarized update, installs it only if it is signed by the same team, and relaunches iGhostVT. Every terminal on \(displayName) ends.")
            : String(localized: "iGhostVT downloads the notarized update, installs it only if it is signed by the same team, and relaunches. Every terminal on this Mac ends.")
        present(AlertViewController(
            content: AlertViewController.Content(
                title: isRemote
                    ? String(localized: "Install iGhostVT \(version) on \(displayName)?")
                    : String(localized: "Install iGhostVT \(version)?"),
                message: message,
            ),
            actions: [
                AlertAction("Later") { self.end() },
                AlertAction("Install", kind: .highlighted) {
                    Task { await self.install(version) }
                },
            ],
        ))
    }

    private func install(_ version: String) async {
        showProgress(String(localized: "Downloading iGhostVT \(version)"), progress: .fraction(0))
        var status = await follow(HostUpdateClient.ask(at: endpoint, install: true))
        guard !isCancelled else { return end() }
        // Past the swap the helper restarts, so the answer can be a lost
        // link or a fresh helper that knows of no update (`idle`) — a fast
        // download gets there between two asks. What the host runs now
        // decides.
        if status?.state != .installed, status.map({ $0.state == .idle }) ?? true {
            showProgress(String(localized: "Installing iGhostVT \(version)"), progress: .indeterminate, cancellable: false)
            if let settled = await settledVersion(version) {
                status = settled
            }
        }
        guard !isCancelled else { return end() }
        if let status, status.state != .installed, status.installedVersion == version {
            return closeProgress { self.showInstalled(version: version) }
        }
        switch status?.state {
        case .installed:
            closeProgress { self.showInstalled(version: version) }
        case nil:
            // The host stopped answering after the swap: its helper is
            // restarting, which is the end of a good install too.
            conclude(
                title: String(localized: "Update Sent"),
                message: String(localized: "\(displayName) stopped answering while it installed iGhostVT \(version). It is most likely restarting iGhostVT; open new terminals once it is back."),
            )
        default:
            conclude(
                title: String(localized: "Unable to Install the Update"),
                message: status?.message ?? String(localized: "Unable to complete this action. Try again."),
            )
        }
    }

    private func showInstalled(version: String) {
        guard isRemote else {
            // The app relaunches the moment the Mac says the copy is in
            // place (`MacLaunchAgent.watchForInstalledUpdate`); this is
            // what shows until it does.
            showProgress(String(localized: "Restarting iGhostVT…"), progress: .indeterminate, cancellable: false)
            // Should the relaunch not come, the alert says what to do.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                conclude(
                    title: String(localized: "iGhostVT \(version) Installed"),
                    message: String(localized: "Quit iGhostVT and open it again to use the new version."),
                )
            }
            return
        }
        present(AlertViewController(
            title: "iGhostVT \(version) Installed",
            message: "\(displayName) is restarting iGhostVT. Its terminals ended; open new ones once it is back.",
            actions: [AlertAction("Done", kind: .highlighted) { self.end() }],
        ))
    }

    /// Asks again until the state settles, keeping the progress alert in
    /// step. Nil when the host stops answering (two misses in a row).
    private func follow(_ first: HostUpdateStatus?) async -> HostUpdateStatus? {
        var status = first
        var misses = 0
        while !isCancelled {
            if let status, !status.state.isBusy {
                return status
            }
            if let status {
                misses = 0
                show(status)
            } else {
                misses += 1
                if misses >= 2 {
                    return nil
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            status = await HostUpdateClient.ask(at: endpoint)
        }
        return status
    }

    /// Asks for half a minute, while the helper restarts, until the host
    /// reports `version` as installed; the last answer otherwise (nil when
    /// none came).
    private func settledVersion(_ version: String) async -> HostUpdateStatus? {
        var last: HostUpdateStatus?
        for _ in 0 ..< 15 where !isCancelled {
            if let status = await HostUpdateClient.ask(at: endpoint, timeout: 5) {
                last = status
                if status.installedVersion == version {
                    return status
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return last
    }

    private func show(_ status: HostUpdateStatus) {
        guard let content else { return }
        let version = status.latestVersion ?? ""
        switch status.state {
        case .downloading:
            let fraction = status.progress ?? 0
            content.title = String(localized: "Downloading iGhostVT \(version)")
            content.message = fraction.formatted(.percent.precision(.fractionLength(0)))
            content.progress = .fraction(fraction)
        case .verifying:
            content.title = String(localized: "Checking the Signature")
            content.message = String(localized: "iGhostVT \(version)")
            content.progress = .indeterminate
        case .installing:
            content.title = String(localized: "Installing iGhostVT \(version)")
            content.message = ""
            content.progress = .indeterminate
        default:
            break
        }
    }

    // MARK: - Alerts

    private func showProgress(_ title: String, progress: AlertProgress, cancellable: Bool = true) {
        if let content {
            content.title = title
            content.message = ""
            content.progress = progress
            return
        }
        let content = AlertViewController.Content(title: title, progress: progress)
        let alert = AlertViewController(
            content: content,
            // Cancel stops the Mac too: a check, or an install that has not
            // reached the swap. Past it there is nothing left to stop.
            actions: cancellable ? [AlertAction("Cancel") { self.cancel() }] : [],
        )
        alert.onDismissUnanswered = { [weak self] in self?.cancel() }
        self.content = content
        self.alert = alert
        present(alert)
    }

    private func closeProgress(then next: @escaping () -> Void) {
        let alert = alert
        self.alert = nil
        content = nil
        if let alert {
            alert.close(then: next)
        } else {
            next()
        }
    }

    private func conclude(title: String, message: String, orUnsupported: Bool = false) {
        closeProgress {
            if orUnsupported, let unsupported = self.unsupported {
                self.end()
                unsupported(message.isEmpty ? nil : message)
                return
            }
            self.present(AlertViewController(
                content: AlertViewController.Content(title: title, message: message),
                actions: [AlertAction("Done", kind: .highlighted) { self.end() }],
            ))
        }
    }

    private func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let endpoint = endpoint
        Task.detached { _ = await HostUpdateClient.ask(at: endpoint, cancel: true) }
        end()
    }

    /// Every alert of the flow ends it when something other than a button
    /// takes it down — another alert, its window closing — and one that
    /// cannot be shown at all ends it at once, so the flow never stays
    /// marked as running.
    private func present(_ alert: AlertViewController) {
        // A flow already over (cancelled, or a window that went away)
        // shows nothing more.
        guard !hasEnded else { return }
        if alert.onDismissUnanswered == nil {
            alert.onDismissUnanswered = { [weak self] in self?.end() }
        }
        guard let window = window ?? Self.keyWindow else {
            AppLog.warning(.app, "update: no window to show the update in")
            return end()
        }
        alert.present(in: window)
    }

    private var hasEnded = false

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        if let alert {
            self.alert = nil
            content = nil
            alert.close()
        }
        finished()
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
