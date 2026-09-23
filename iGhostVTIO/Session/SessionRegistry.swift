import Darwin
import Dispatch
import Foundation
import os

/// The daemon's store of live terminal sessions.
///
/// Sessions belong to the registry, not to whichever connection created them,
/// so closing the app detaches rather than kills. A relaunched app lists what
/// is still running and reattaches to it.
final class SessionRegistry {
    private let queue: DispatchQueue
    private var sessions: [UInt64: PTYSession] = [:]
    private var attachments: [UInt64: PeerSession] = [:]
    private var nextID: UInt64 = 1
    private var childExitSignal: DispatchSourceSignal?
    private var isOutputPaused = false

    var isEmpty: Bool {
        sessions.isEmpty
    }

    init(queue: DispatchQueue) {
        self.queue = queue
        // The authoritative reaper under every session's own exit source
        // (see PTYSession.start for the kernel ordering): SIGCHLD is sent
        // once the child is waitable, coalesced and naming no pid, so every
        // live session gets asked. SIGCHLD stays SIG_DFL (main.swift): the
        // source observes delivery, and SIG_IGN would auto-reap.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        signalSource.setEventHandler { [weak self] in
            guard let self else { return }
            for session in sessions.values {
                session.reapIfExited()
            }
        }
        signalSource.activate()
        childExitSignal = signalSource
    }

    /// One `listSessions` row. A struct rather than a tuple so the peer that
    /// serialises it and this registry cannot drift apart on a field.
    struct Summary {
        var id: UInt64
        /// The spawned program's name — what the session *is*, fixed at
        /// birth; the live foreground process is `processName`.
        var title: String
        var columns: UInt16
        var rows: UInt16
        var isAttached: Bool
        var processName: String
        var isForegroundShell: Bool
        /// The shell's current directory as the kernel spells it, `nil`
        /// once the child is gone. The raw read, not `inheritableDirectory`:
        /// that one's `stat` exists to refuse a `chdir` target, and for
        /// display the kernel's answer is the truth even for a directory
        /// that has since been removed.
        var currentDirectory: String?
    }

    var summaries: [Summary] {
        sessions.values
            .sorted { $0.id < $1.id }
            .map {
                Summary(
                    id: $0.id,
                    title: $0.command.first.map { path in
                        (path as NSString).lastPathComponent
                    } ?? "shell",
                    columns: $0.columns,
                    rows: $0.rows,
                    isAttached: attachments[$0.id] != nil,
                    processName: $0.foregroundProcessName,
                    isForegroundShell: $0.isForegroundShell,
                    currentDirectory: $0.currentDirectory
                )
            }
    }

    func session(_ id: UInt64) -> PTYSession? {
        sessions[id]
    }

    /// `inheritDirectoryFrom` names a live session whose shell's current
    /// directory the new one starts in — how a new tab opens where the
    /// current one is. The directory is read from the kernel here, not
    /// carried over the wire, so nothing the app says picks a path; a
    /// session that is gone, or a directory that is not one any more,
    /// simply means the plan's own start (the home).
    ///
    /// `startDirectory` is the other half of that, for a directory no live
    /// session can name any more — the client's recent list. It is a path
    /// the daemon itself reported, handed back, and it is checked here the
    /// same way an inherited one is: a path that is not a directory right
    /// now means the home, never a failed open.
    func open(
        command requestedCommand: [String],
        shell requestedShell: String? = nil,
        environment requestedEnvironment: [String: String],
        columns: UInt16,
        rows: UInt16,
        inheritDirectoryFrom sourceSessionID: UInt64? = nil,
        startDirectory: String? = nil
    ) throws -> PTYSession {
        guard sessions.count < iGhostVTProtocol.maximumSessions else {
            throw iGhostVTFailure(
                .sessionLimitReached,
                "You already have \(sessions.count) terminals open. Close one and try again."
            )
        }
        let plan = try resolvePlan(command: requestedCommand, shell: requestedShell)
        // A live session outranks a remembered path: it is the same
        // directory read a moment ago instead of whenever the client last
        // saw it.
        let requestedDirectory = sourceSessionID.flatMap(inheritableDirectory)
            ?? startDirectory.flatMap(enterableDirectory)
        let id = nextID
        nextID &+= 1

        let session = try PTYSession(
            id: id,
            command: plan.command,
            environment: plan.environment.merging(requestedEnvironment) { _, client in client },
            columns: clamp(columns, fallback: iGhostVTProtocol.defaultColumns, limit: iGhostVTProtocol.maximumColumns),
            rows: clamp(rows, fallback: iGhostVTProtocol.defaultRows, limit: iGhostVTProtocol.maximumRows),
            credentials: plan.credentials,
            workingDirectory: requestedDirectory ?? plan.workingDirectory,
            fallbackWorkingDirectory: requestedDirectory == nil ? nil : plan.workingDirectory,
            queue: queue
        )
        sessions[id] = session
        DaemonLog.sessions.info(
            "session \(id) spawned \(plan.command.first ?? "?", privacy: .public), \(self.sessions.count)/\(iGhostVTProtocol.maximumSessions) held"
        )
        DaemonFileLog.log(
            "session \(id) spawned \(plan.command.first ?? "?")"
                + (requestedDirectory.map { " in \($0)" } ?? "")
                + (sourceSessionID.map { " (from session \($0))" } ?? "")
                + ", \(sessions.count)/\(iGhostVTProtocol.maximumSessions) held"
        )
        session.start(
            onOutput: { [weak self] sessionID, data in
                self?.attachments[sessionID]?.deliverOutput(sessionID: sessionID, data: data)
            },
            onExit: { [weak self] sessionID, exitCode in
                self?.handleExit(sessionID: sessionID, exitCode: exitCode)
            },
            onForegroundChange: { [weak self] session in
                self?.attachments[session.id]?.deliverForeground(of: session)
            }
        )
        if isOutputPaused {
            session.setOutputPaused(true)
        }
        return session
    }

    /// Flow control from the proxy link: while the output already produced
    /// is not being taken, no session reads more off its PTY. A session
    /// opened meanwhile starts paused too.
    func setOutputPaused(_ paused: Bool) {
        guard paused != isOutputPaused else { return }
        isOutputPaused = paused
        for session in sessions.values {
            session.setOutputPaused(paused)
        }
    }

    func attach(_ id: UInt64, to peer: PeerSession) throws -> PTYSession {
        guard let session = sessions[id] else {
            throw iGhostVTReplyCode.unknownSession
        }
        if let existing = attachments[id], existing !== peer {
            throw iGhostVTReplyCode.sessionBusy
        }
        attachments[id] = peer
        return session
    }

    func detach(_ id: UInt64, from peer: PeerSession) {
        guard attachments[id] === peer else { return }
        attachments.removeValue(forKey: id)
    }

    func detachAll(for peer: PeerSession) {
        for (id, attached) in attachments where attached === peer {
            attachments.removeValue(forKey: id)
        }
    }

    /// How long a closed shell gets to exit on its own before it is killed.
    /// Long enough for a shell to run its exit hooks, short enough that the
    /// user never notices the session is still there.
    private static let closeGracePeriod: DispatchTimeInterval = .seconds(2)

    /// Explicit user-initiated close: the shell goes away for good, and so
    /// does everything the daemon was holding for it.
    ///
    /// `SIGHUP` alone is not a release. It is asynchronous, and a shell is
    /// free to ignore it — so the old "terminate and let the exit handler
    /// clean up" shape leaked the PTY, the replay buffer and the registry
    /// entry for any session that declined to die. Ask nicely, then take it.
    func close(_ id: UInt64) throws {
        guard let session = sessions[id] else {
            DaemonLog.sessions.info("close of session \(id): unknown, already gone")
            throw iGhostVTReplyCode.unknownSession
        }
        DaemonLog.sessions.info("session \(id) close requested, SIGHUP sent")
        session.terminate()
        queue.asyncAfter(deadline: .now() + Self.closeGracePeriod) { [weak self] in
            guard let self, sessions[id] === session else { return }
            handleExit(sessionID: id, exitCode: 128 + SIGKILL)
        }
    }

    // MARK: - Internals

    /// Drops a session, telling whoever is still attached — otherwise the app
    /// keeps a tab pointing at a session the daemon no longer has.
    private func handleExit(sessionID: UInt64, exitCode: Int32) {
        DaemonLog.sessions.info(
            "session \(sessionID) exited with status \(exitCode), \(self.sessions.count - 1) remain"
        )
        DaemonFileLog.log(
            "session \(sessionID) exited with status \(exitCode), \(sessions.count - 1) remain"
        )
        attachments[sessionID]?.deliverExit(sessionID: sessionID, exitCode: exitCode)
        discard(sessionID)
    }

    /// The only way a session leaves the registry. `invalidate()` cancels the
    /// dispatch sources, kills the child if it is somehow still alive, and
    /// closes the master — and dropping the last reference frees the replay
    /// buffer with it.
    private func discard(_ id: UInt64) {
        attachments.removeValue(forKey: id)
        sessions.removeValue(forKey: id)?.invalidate()
    }

    /// The directory a new session may inherit from `sourceSessionID`:
    /// its shell's current one, if the session is still alive and the path
    /// is a directory right now.
    func inheritableDirectory(from sourceSessionID: UInt64) -> String? {
        sessions[sourceSessionID]?.currentDirectory.flatMap(enterableDirectory)
    }

    /// A path a session may start in: absolute, and a directory right now.
    /// Checked as the daemon; the child re-checks as the session user when
    /// it `chdir`s, and falls back if refused — so this is a sanity test,
    /// not the permission one.
    func enterableDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count < Int(MAXPATHLEN) else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return path
    }

    /// A client sends an argv it wants run verbatim (`cmd`, one word
    /// included — the CLI and Shortcuts), or none of that and either a shell
    /// path (`shell`, the app's Settings choice) or nothing (give me a
    /// shell). The two are different keys because a one-word `cmd` used to
    /// be read as the shell choice, and `python3 -il` is not a session.
    private func resolvePlan(command requested: [String], shell requestedShell: String?) throws -> ShellLaunch.Plan {
        if !requested.isEmpty {
            guard let command = ShellLaunch.validate(requested) else {
                throw iGhostVTFailure(
                    .invalidRequest,
                    "Unable to run that command. Check the command and try again."
                )
            }
            return ShellLaunch.verbatimPlan(command: command)
        }
        if let requestedShell, !requestedShell.isEmpty {
            guard let plan = ShellLaunch.plan(requestedShell: requestedShell) else {
                throw iGhostVTFailure(
                    .invalidRequest,
                    "Unable to run \(requestedShell). Choose another shell in Settings."
                )
            }
            return plan
        }
        guard let plan = ShellLaunch.plan(requestedShell: nil) else {
            throw iGhostVTFailure(
                .spawnFailed,
                "No usable shell was found. Check the default shell in Settings."
            )
        }
        return plan
    }

    private func clamp(_ value: UInt16, fallback: UInt16, limit: UInt16) -> UInt16 {
        guard value > 0 else { return fallback }
        return min(value, limit)
    }
}

extension iGhostVTReplyCode: Error {}
