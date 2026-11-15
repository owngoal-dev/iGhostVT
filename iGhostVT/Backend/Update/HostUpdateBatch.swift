import Combine
import UIKit

/// Updating paired Macs from the Mac's Accessible Devices, several at once:
/// every chosen device is asked to check, the person confirms once for all
/// that have an update, and each then downloads, checks and installs on its
/// own (`MacUpdater`), its progress on its own row. A device that is up to
/// date, or cannot update itself, says so on its row and is left alone.
///
/// The Mac does the work and this only asks, as `HostUpdateFlow` does for
/// one device in alerts; it outlives the sheet, so closing it stops
/// nothing, and opening it again shows where each device is.
@MainActor
final class HostUpdateBatch: ObservableObject {
    static let shared = HostUpdateBatch()

    enum Phase: Equatable {
        case checking
        case upToDate(version: String)
        /// Found and waiting for the person's go, or left for later.
        case available(version: String)
        /// The host cannot update itself; `message` says why, in its words.
        case unsupported(message: String)
        case downloading(version: String, fraction: Double)
        case verifying(version: String)
        case installing(version: String)
        /// In place; the host's iGhostVT is restarting.
        case restarting(version: String)
        case updated(version: String)
        /// It stopped answering after the swap and has not come back yet:
        /// most likely still restarting.
        case unconfirmed(version: String)
        case failed(message: String)

        /// Still moving: the row shows progress and the batch waits.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing, .restarting: true
            default: false
            }
        }

        /// How far along an install is, for the overall bar; nil for a
        /// phase that is no install.
        var installFraction: Double? {
            switch self {
            case let .downloading(_, fraction): 0.75 * min(max(fraction, 0), 1)
            case .verifying: 0.8
            case .installing: 0.88
            case .restarting: 0.95
            case .updated, .unconfirmed: 1
            default: nil
            }
        }
    }

    @Published private(set) var phases: [String: Phase] = [:]
    /// Each host's current run: a newer run, or Cancel, retires the one
    /// before, whose asks then change nothing.
    private var runs: [String: Int] = [:]
    private var nextRun = 0
    /// The hosts that began installing since nothing was last moving: the
    /// overall bar measures these, not what finished before, and one that
    /// failed counts as done rather than pulling the bar back.
    private var installs: Set<String> = []
    /// A check is running, or its confirmation is up: a second one would
    /// take that alert's place, and alerts do not stack.
    @Published private(set) var isAsking = false
    /// Which check `isAsking` belongs to: Cancel ends it at once, and the
    /// check's own end then leaves a newer one alone.
    private var asking = 0
    /// The confirmation on its way or on screen. Held here: the presenter
    /// keeps only a weak reference while another alert is up, and an alert
    /// nothing held was gone by the time it could show.
    private var confirmation: AlertViewController?
    private var observer: NSObjectProtocol?

    private init() {
        // A device forgotten mid-run takes its row away; its phase goes too,
        // so nothing stays busy for a row that is not there.
        observer = NotificationCenter.default.addObserver(
            forName: PairedRemoteHostStore.didChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let paired = Set(PairedRemoteHostStore.hosts.map(\.id))
                for hostID in self.phases.keys where !paired.contains(hostID) {
                    self.runs.removeValue(forKey: hostID)
                    self.phases.removeValue(forKey: hostID)
                    self.installs.remove(hostID)
                }
            }
        }
    }

    /// Whether anything is still moving.
    var isBusy: Bool {
        phases.values.contains(where: \.isBusy)
    }

    /// Whether Cancel can stop something: a check, a download or a
    /// signature check. Past that the host is replacing itself.
    var isCancellable: Bool {
        phases.values.contains(where: Self.isCancellable)
    }

    /// The overall bar: how far the installs of this batch have come, nil
    /// while none is under way (a check alone has no measure).
    var overallFraction: Double? {
        guard installingCount > 0 else { return nil }
        let fractions = installs.map { phases[$0]?.installFraction ?? 1 }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    /// How many hosts are installing right now.
    var installingCount: Int {
        installs.filter { phases[$0]?.isBusy == true }.count
    }

    var isChecking: Bool {
        phases.values.contains(.checking)
    }

    // MARK: - Running

    /// Checks each host not already busy, then asks once to install on
    /// every one that has an update. Nothing while another check, or its
    /// confirmation, is still up.
    func update(_ hostIDs: [String], in window: UIWindow?) {
        let hostIDs = hostIDs.filter { phases[$0]?.isBusy != true }
        guard !hostIDs.isEmpty, !isAsking else { return }
        if !isBusy {
            installs.removeAll()
        }
        asking += 1
        let ask = asking
        isAsking = true
        var started: [(hostID: String, run: Int)] = []
        for hostID in hostIDs {
            nextRun += 1
            runs[hostID] = nextRun
            phases[hostID] = .checking
            // Checking again is not installing: out of the overall bar.
            installs.remove(hostID)
            started.append((hostID, nextRun))
        }
        // Weak: a Settings window closed meanwhile must not take the alert
        // with it; the frontmost window shows it instead.
        Task { [weak window] in
            var found: [Found] = []
            await withTaskGroup(of: Found?.self) { group in
                for item in started {
                    group.addTask { await self.check(item.hostID, run: item.run) }
                }
                for await item in group {
                    if let item {
                        found.append(item)
                    }
                }
            }
            // Cancel retires a run that found an update too, and a host
            // asked again or forgotten meanwhile is no longer this one's.
            found = found.filter { isCurrent($0.hostID, $0.run) && phases[$0.hostID] == .available(version: $0.version) }
            guard ask == asking else { return }
            guard !found.isEmpty else {
                isAsking = false
                return
            }
            // The order the person sees in the list.
            let order = PairedRemoteHostStore.hosts.map(\.id)
            found.sort { (order.firstIndex(of: $0.hostID) ?? .max) < (order.firstIndex(of: $1.hostID) ?? .max) }
            confirm(found, in: window, ask: ask)
        }
    }

    /// Stops every check and download it can, and the confirmation the
    /// checks were heading for; a host already replacing itself carries on.
    /// The host has the last word: one that got past the point of no return
    /// before the cancel reached it is followed again.
    func cancel() {
        // The check's confirmation is off too: the buttons come back now,
        // not once the asks still out have timed out.
        asking += 1
        isAsking = false
        for (hostID, phase) in phases {
            if case .available = phase {
                // Found while others still checked: no alert for it now.
                runs.removeValue(forKey: hostID)
            }
            guard Self.isCancellable(phase) else { continue }
            runs.removeValue(forKey: hostID)
            phases.removeValue(forKey: hostID)
            installs.remove(hostID)
            Task {
                // The row is gone, so the cancel has to land: a link that
                // drops it is tried again, and a host that never hears it
                // may still be updating, which the row then says.
                var status: HostUpdateStatus?
                for attempt in 0 ..< 3 where status == nil {
                    if attempt > 0 {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    guard runs[hostID] == nil else { return }
                    status = await HostUpdateClient.ask(at: .remote(hostID: hostID), cancel: true)
                }
                guard runs[hostID] == nil else { return }
                guard let status else {
                    phases[hostID] = .failed(message: Self.noAnswer(hostID))
                    return
                }
                switch status.state {
                case .installing, .installed:
                    let version = status.latestVersion ?? ""
                    nextRun += 1
                    let run = nextRun
                    runs[hostID] = run
                    installs.insert(hostID)
                    if status.state == .installed {
                        phases[hostID] = .restarting(version: version)
                        await settle(hostID, run: run, version: version)
                    } else {
                        phases[hostID] = .installing(version: version)
                        await finishInstall(hostID, run: run, version: version, from: status)
                    }
                default:
                    break
                }
            }
        }
    }

    /// Forgets what the finished runs said, for a list opened afresh.
    /// What is still moving stays, and so does an update found but not
    /// installed, which the rows keep offering; nothing goes while a check
    /// is still heading for its confirmation.
    func clearSettled() {
        guard !isAsking else { return }
        phases = phases.filter { entry in
            if case .available = entry.value {
                return true
            }
            return entry.value.isBusy
        }
    }

    private static func isCancellable(_ phase: Phase) -> Bool {
        switch phase {
        case .checking, .downloading, .verifying: true
        default: false
        }
    }

    private struct Found {
        let hostID: String
        let run: Int
        let version: String
        let installed: String
    }

    private func isCurrent(_ hostID: String, _ run: Int) -> Bool {
        runs[hostID] == run
    }

    /// One host's check, followed to an answer and shown on its row; what
    /// it found when there is an update to install.
    private func check(_ hostID: String, run: Int) async -> Found? {
        let status = await follow(
            hostID,
            run: run,
            HostUpdateClient.ask(at: .remote(hostID: hostID), check: true),
            untilInstalling: true,
        )
        guard isCurrent(hostID, run) else { return nil }
        if let status, Self.isInstalling(status.state) {
            // Already installing for someone else (its own menu, another
            // device): followed on its own, so the others' confirmation
            // does not wait for its download.
            installs.insert(hostID)
            show(status, for: hostID)
            Task { await finishInstall(hostID, run: run, version: status.latestVersion ?? "", from: status) }
            return nil
        }
        guard let status else {
            phases[hostID] = .failed(message: Self.noAnswer(hostID))
            return nil
        }
        RemoteHostVersions.shared.note(status, fromHostID: hostID)
        switch status.state {
        case .upToDate:
            phases[hostID] = .upToDate(version: status.installedVersion)
        case .available:
            let version = status.latestVersion ?? ""
            phases[hostID] = .available(version: version)
            return Found(hostID: hostID, run: run, version: version, installed: status.installedVersion)
        case .unsupported:
            phases[hostID] = .unsupported(message: status.message ?? "")
        case .installed:
            // Someone else's install got there first: see it through, and
            // do not hold the others' confirmation for it.
            let version = status.latestVersion ?? ""
            installs.insert(hostID)
            phases[hostID] = .restarting(version: version)
            Task { await settle(hostID, run: run, version: version) }
        default:
            phases[hostID] = .failed(message: status.message ?? Self.tryAgain)
        }
        return nil
    }

    private func confirm(_ found: [Found], in window: UIWindow?, ask: Int) {
        let versions = Set(found.map(\.version))
        let content: AlertViewController.Content
        if found.count == 1, let only = found.first {
            let name = Self.name(only.hostID)
            content = AlertViewController.Content(
                title: String(localized: "Install iGhostVT \(only.version) on \(name)?"),
                message: String(localized: "\(name) runs iGhostVT \(only.installed). It downloads the notarized update, installs it only if it is signed by the same team, and relaunches iGhostVT. Every terminal on \(name) ends."),
            )
        } else {
            let names = ListFormatter.localizedString(byJoining: found.map { Self.name($0.hostID) })
            // The message names every device, so the title needs no count.
            let title = if versions.count == 1, let version = versions.first {
                String(localized: "Install iGhostVT \(version)?")
            } else {
                String(localized: "Install Updates?", comment: "Confirming an update of several paired Macs that found different versions")
            }
            content = AlertViewController.Content(
                title: title,
                message: String(
                    localized: "\(names) each download the notarized update, install it only if it is signed by the same team, and relaunch iGhostVT. Every terminal on them ends.",
                    comment: "Confirming an update of several paired Macs; the list names them",
                ),
            )
        }
        let alert = AlertViewController(
            content: content,
            actions: [
                // The rows keep saying an update is there.
                AlertAction("Later") { [self] in finishAsking(ask) },
                AlertAction("Install", kind: .highlighted) { [self] in
                    finishAsking(ask)
                    for item in found {
                        install(item)
                    }
                },
            ],
        )
        alert.onDismissUnanswered = { [weak self] in self?.finishAsking(ask) }
        // The Settings window may have closed while the devices checked.
        let onScreen = window.flatMap { window -> UIWindow? in
            switch window.windowScene?.activationState {
            case .foregroundActive, .foregroundInactive: window
            default: nil
            }
        }
        guard let target = onScreen ?? HostUpdateFlow.keyWindow else {
            finishAsking(ask)
            return
        }
        confirmation = alert
        alert.present(in: target)
    }

    /// The confirmation of check `ask` was answered or went away.
    private func finishAsking(_ ask: Int) {
        confirmation = nil
        if ask == asking {
            isAsking = false
        }
    }

    private func install(_ item: Found) {
        let hostID = item.hostID
        let version = item.version
        // Asked again, or cancelled, since the check: leave it.
        guard isCurrent(hostID, item.run), phases[hostID] == .available(version: version) else { return }
        let run = item.run
        installs.insert(hostID)
        phases[hostID] = .downloading(version: version, fraction: 0)
        Task {
            await finishInstall(hostID, run: run, version: version, from: HostUpdateClient.ask(at: .remote(hostID: hostID), install: true))
        }
    }

    /// Follows an install from `first` to its end on the row.
    private func finishInstall(_ hostID: String, run: Int, version: String, from first: HostUpdateStatus?) async {
        let status = await follow(hostID, run: run, first)
        guard isCurrent(hostID, run) else { return }
        // Past the swap the helper restarts, so the answer can be a
        // lost link or a fresh helper that knows of no update (`idle`):
        // what the host runs then decides.
        // A copy on a new release line refuses this one's hello: the host
        // restarted into it, which `settle` confirms.
        if let status, status.state != .installed, status.state != .idle, !status.isOtherLine {
            if Self.isRunning(version, status) {
                RemoteHostVersions.shared.note(status, fromHostID: hostID)
                phases[hostID] = .updated(version: version)
            } else if status.state == .available {
                // Cancelled on the host itself.
                phases[hostID] = .available(version: status.latestVersion ?? version)
            } else {
                phases[hostID] = .failed(message: status.message ?? Self.tryAgain)
            }
            return
        }
        phases[hostID] = .restarting(version: version)
        await settle(hostID, run: run, version: version)
    }

    /// Waits about a minute for the host to come back running `version`.
    /// A host that answers still downloading lost a moment of its link,
    /// not its copy: it is followed again from there.
    private func settle(_ hostID: String, run: Int, version: String) async {
        for _ in 0 ..< 20 {
            guard isCurrent(hostID, run) else { return }
            if let status = await HostUpdateClient.ask(at: .remote(hostID: hostID), timeout: 5) {
                guard isCurrent(hostID, run) else { return }
                RemoteHostVersions.shared.note(status, fromHostID: hostID)
                if Self.isRunning(version, status) {
                    phases[hostID] = .updated(version: version)
                    // Its terminals, asked afresh from the new copy.
                    Task { await RemoteSessionCatalog.shared.refresh(hostID: hostID) }
                    return
                }
                switch status.state {
                case .checking, .downloading, .verifying, .installing:
                    show(status, for: hostID)
                    return await finishInstall(hostID, run: run, version: version, from: status)
                case .failed:
                    phases[hostID] = .failed(message: status.message ?? Self.tryAgain)
                    return
                case .available:
                    phases[hostID] = .available(version: status.latestVersion ?? version)
                    return
                default:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        guard isCurrent(hostID, run) else { return }
        phases[hostID] = .unconfirmed(version: version)
    }

    /// Asks again until the state settles, keeping the row in step. Nil
    /// when the host stops answering (two misses in a row) or the run was
    /// retired. `untilInstalling` returns as soon as the host is
    /// installing, for a check that should not wait for it.
    private func follow(
        _ hostID: String,
        run: Int,
        _ first: HostUpdateStatus?,
        untilInstalling: Bool = false,
    ) async -> HostUpdateStatus? {
        var status = first
        var misses = 0
        while isCurrent(hostID, run) {
            if let status, !status.state.isBusy || untilInstalling && Self.isInstalling(status.state) {
                return status
            }
            if let status {
                misses = 0
                show(status, for: hostID)
            } else {
                misses += 1
                if misses >= 2 {
                    return nil
                }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
            guard isCurrent(hostID, run) else { break }
            status = await HostUpdateClient.ask(at: .remote(hostID: hostID))
        }
        // Retired by Cancel while an ask was on its way: an install the host
        // began after the cancel reached it is stopped now, before it gets
        // to the swap. Never for a host asked again since — that answer may
        // be its new, confirmed install.
        if runs[hostID] == nil, let status, status.state == .downloading || status.state == .verifying {
            Task.detached { _ = await HostUpdateClient.ask(at: .remote(hostID: hostID), cancel: true) }
        }
        return nil
    }

    /// Every ask is a connection of its own, through the relay as often as
    /// not, and the relay takes 60 a host's address in ten seconds: the
    /// more devices are followed, the slower each one is asked.
    private var pollInterval: UInt64 {
        let followed = max(phases.values.filter(\.isBusy).count, 1)
        let seconds = max(1.0, 0.4 * Double(followed))
        return UInt64(seconds * 1_000_000_000)
    }

    /// Whether the host's answer says it runs `version`. A copy on a new
    /// release line refuses this one's hello and says only its line.
    private static func isRunning(_ version: String, _ status: HostUpdateStatus) -> Bool {
        status.isOtherLine
            ? status.installedVersion == RemoteAccess.wireSpelling(of: version)
            : status.installedVersion == version
    }

    private static func isInstalling(_ state: HostUpdateState) -> Bool {
        state == .downloading || state == .verifying || state == .installing
    }

    private func show(_ status: HostUpdateStatus, for hostID: String) {
        let version = status.latestVersion ?? ""
        switch status.state {
        case .checking:
            phases[hostID] = .checking
        case .downloading:
            phases[hostID] = .downloading(version: version, fraction: status.progress ?? 0)
        case .verifying:
            phases[hostID] = .verifying(version: version)
        case .installing:
            phases[hostID] = .installing(version: version)
        default:
            break
        }
    }

    private static var tryAgain: String {
        String(localized: "Unable to complete this action. Try again.")
    }

    private static func name(_ hostID: String) -> String {
        PairedRemoteHostStore.host(id: hostID)?.displayName ?? String(localized: "the other device")
    }

    private static func noAnswer(_ hostID: String) -> String {
        String(localized: "\(name(hostID)) did not answer. Check that it is on and try again.")
    }
}
