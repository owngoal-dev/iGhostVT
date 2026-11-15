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
    /// The hosts of the runs since nothing was last moving: the overall
    /// bar measures these, not what finished before.
    private var batch: Set<String> = []

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
        let installs = batch.compactMap { phases[$0] }.filter { $0.installFraction != nil }
        guard installs.contains(where: \.isBusy) else { return nil }
        return installs.compactMap(\.installFraction).reduce(0, +) / Double(installs.count)
    }

    /// How many hosts are installing right now.
    var installingCount: Int {
        phases.values.filter { $0.isBusy && $0.installFraction != nil }.count
    }

    var isChecking: Bool {
        phases.values.contains(.checking)
    }

    // MARK: - Running

    /// Checks each host not already busy, then asks once to install on
    /// every one that has an update.
    func update(_ hostIDs: [String], in window: UIWindow?) {
        let hostIDs = hostIDs.filter { phases[$0]?.isBusy != true }
        guard !hostIDs.isEmpty else { return }
        if !isBusy {
            batch.removeAll()
        }
        var started: [(hostID: String, run: Int)] = []
        for hostID in hostIDs {
            nextRun += 1
            runs[hostID] = nextRun
            batch.insert(hostID)
            phases[hostID] = .checking
            started.append((hostID, nextRun))
        }
        Task {
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
            guard !found.isEmpty else { return }
            // The order the person sees in the list.
            let order = PairedRemoteHostStore.hosts.map(\.id)
            found.sort { (order.firstIndex(of: $0.hostID) ?? .max) < (order.firstIndex(of: $1.hostID) ?? .max) }
            confirm(found, in: window)
        }
    }

    /// Stops every check and download it can; a host already replacing
    /// itself carries on.
    func cancel() {
        for (hostID, phase) in phases where Self.isCancellable(phase) {
            runs.removeValue(forKey: hostID)
            phases.removeValue(forKey: hostID)
            Task.detached { _ = await HostUpdateClient.ask(at: .remote(hostID: hostID), cancel: true) }
        }
    }

    /// Forgets what the finished runs said, for a list opened afresh.
    func clearSettled() {
        phases = phases.filter { $0.value.isBusy }
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
        let status = await follow(hostID, run: run, HostUpdateClient.ask(at: .remote(hostID: hostID), check: true))
        guard isCurrent(hostID, run) else { return nil }
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
            phases[hostID] = .restarting(version: version)
            Task { await settle(hostID, run: run, version: version) }
        default:
            phases[hostID] = .failed(message: status.message ?? Self.tryAgain)
        }
        return nil
    }

    private func confirm(_ found: [Found], in window: UIWindow?) {
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
                AlertAction("Later") {},
                AlertAction("Install", kind: .highlighted) { [self] in
                    for item in found {
                        install(item)
                    }
                },
            ],
        )
        guard let window = window ?? HostUpdateFlow.keyWindow else { return }
        alert.present(in: window)
    }

    private func install(_ item: Found) {
        let hostID = item.hostID
        let version = item.version
        // Asked again, or cancelled, since the check: leave it.
        guard isCurrent(hostID, item.run), phases[hostID] == .available(version: version) else { return }
        let run = item.run
        phases[hostID] = .downloading(version: version, fraction: 0)
        Task {
            let status = await follow(hostID, run: run, HostUpdateClient.ask(at: .remote(hostID: hostID), install: true))
            guard isCurrent(hostID, run) else { return }
            // Past the swap the helper restarts, so the answer can be a
            // lost link or a fresh helper that knows of no update (`idle`):
            // what the host runs then decides.
            if let status, status.state != .installed, status.state != .idle {
                if status.installedVersion == version {
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
    }

    /// Waits about a minute for the host to come back running `version`.
    private func settle(_ hostID: String, run: Int, version: String) async {
        for _ in 0 ..< 20 {
            guard isCurrent(hostID, run) else { return }
            if let status = await HostUpdateClient.ask(at: .remote(hostID: hostID), timeout: 5) {
                guard isCurrent(hostID, run) else { return }
                RemoteHostVersions.shared.note(status, fromHostID: hostID)
                if status.installedVersion == version {
                    phases[hostID] = .updated(version: version)
                    // Its terminals, asked afresh from the new copy.
                    Task { await RemoteSessionCatalog.shared.refresh(hostID: hostID) }
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard isCurrent(hostID, run) else { return }
        phases[hostID] = .unconfirmed(version: version)
    }

    /// Asks again until the state settles, keeping the row in step. Nil
    /// when the host stops answering (two misses in a row) or the run was
    /// retired.
    private func follow(_ hostID: String, run: Int, _ first: HostUpdateStatus?) async -> HostUpdateStatus? {
        var status = first
        var misses = 0
        while isCurrent(hostID, run) {
            if let status, !status.state.isBusy {
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
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard isCurrent(hostID, run) else { return nil }
            status = await HostUpdateClient.ask(at: .remote(hostID: hostID))
        }
        return nil
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
