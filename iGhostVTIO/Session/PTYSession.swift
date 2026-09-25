import Darwin
import Dispatch
import Foundation

/// One pseudo-terminal and the process running on it.
///
/// This is the only place in the product that creates a process. The app has
/// no path to `fork`/`exec` at all: it can ask the daemon to open a session
/// and the daemon decides what runs.
final class PTYSession {
    typealias OutputHandler = (UInt64, Data) -> Void
    typealias ExitHandler = (UInt64, Int32) -> Void
    /// Something about what the terminal is doing changed — the foreground
    /// process, whether it is the shell itself, or the shell's directory.
    /// The session hands itself over rather than the values: one reporter
    /// fills event 102 and every open/attach reply, and it reads them from
    /// here, so the two cannot drift apart on a field.
    typealias ForegroundHandler = (PTYSession) -> Void

    let id: UInt64
    let command: [String]
    private(set) var columns: UInt16
    private(set) var rows: UInt16
    private(set) var isAlive = true

    /// Recent output, replayed when a client attaches. The daemon holds this
    /// so a relaunched app can rebuild the screen without the shell knowing
    /// anything happened.
    private var replayBuffer = Data()

    private let queue: DispatchQueue
    private let master: Int32
    private let childPID: pid_t
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// Output is not being read off the PTY: the proxy is not taking it,
    /// so the master's buffer fills and the shell blocks on its write —
    /// what a real terminal does when nobody is reading it.
    private var isOutputPaused = false

    /// Input the kernel has not taken yet, oldest first.
    ///
    /// A PTY master accepts about a kilobyte ahead of the program reading the
    /// terminal (XNU's `TTYHOG - 2`, ~1022 bytes) and answers `EAGAIN` for
    /// the rest — and a paste is one write of everything. Without this
    /// buffer the tail was simply dropped: a 13 KB paste reached the shell as
    /// its first 1022 bytes, cut mid-character, and the bracketed-paste
    /// terminator that followed it was lost with the rest, leaving the
    /// program stuck in paste mode.
    ///
    /// So the remainder waits here and goes in as the program reads, driven
    /// by `writeSource` — a PTY master reports writable exactly when the
    /// slave's input queue has room. Appended to only, in the order writes
    /// arrive, which is what keeps a chunked paste in sequence.
    private var pendingInput: [UInt8] = []
    private var pendingInputOffset = 0
    private var writeSource: DispatchSourceWrite?
    private var isWriteArmed = false

    /// Past this the buffer is handed back to the allocator once drained
    /// rather than kept for the next keystroke.
    private static let retainedInputCapacity = 64 * 1024

    private var onOutput: OutputHandler?
    private var onExit: ExitHandler?
    private var onForegroundChange: ForegroundHandler?

    /// Name of the process group leader currently in the foreground on this
    /// terminal — "sh" at the prompt, "vim" inside vim. Starts as the
    /// spawned executable's name; kept current by a low-rate poll plus a
    /// rate-limited check as output drains.
    private(set) var foregroundProcessName: String

    /// Whether the foreground process group is the spawned shell's own —
    /// the shell sits at its prompt (or has only background jobs), with
    /// nothing running in front of it. The shell is the session leader,
    /// so its group ID is its pid; a job the shell puts in the foreground
    /// runs in a group of its own. True from birth: the spawned program
    /// is the foreground until it hands the terminal to a child.
    private(set) var isForegroundShell = true
    private var processNamePoll: DispatchSourceTimer?
    private var lastProcessNameCheck = DispatchTime(uptimeNanoseconds: 0)

    /// The shell's directory as of the last check — what a client is told,
    /// and what a change is measured against. `nil` until the first read
    /// answers, and again once the child is gone.
    ///
    /// Only the shell's own directory is tracked: `cd` is a shell builtin,
    /// so nothing else can move it, and a `:cd` inside vim is vim's
    /// business. That is also why the read is skipped whenever something is
    /// running in front of the shell — the answer cannot have changed.
    private(set) var reportedDirectory: String?
    private var lastDirectoryCheck = DispatchTime(uptimeNanoseconds: 0)

    /// Floor between directory reads. `cd` changes no process, so the poll
    /// is the only thing that notices one — but it is also the only cost a
    /// session at its prompt pays for the whole feature, and a second's lag
    /// on a directory nobody is looking at yet is worth more than a third
    /// syscall every 500 ms per session.
    private static let directoryPollInterval: UInt64 = NSEC_PER_SEC

    /// Slow on purpose: the poll only exists for foreground changes that
    /// produce no output at all (`sleep`, a silent build). Anything that
    /// prints is caught by the drain-side refresh instead.
    private static let processNamePollInterval: DispatchTimeInterval = .milliseconds(500)

    /// Floor between drain-side checks. The drain sees one of these per 64
    /// KiB, so a shell printing hard would otherwise spend two syscalls per
    /// chunk on a name that changes a few times a second at most.
    private static let processNameDrainInterval: UInt64 = 200 * NSEC_PER_MSEC

    /// Where the child gave up, reported through the spawn pipe. Plain
    /// constants rather than an enum: the child may only make
    /// async-signal-safe calls, and these are read straight into raw memory.
    /// The privilege drop is one step, not four: `setgroups`, `setgid`,
    /// `setuid` and the uid re-check all end the session the same way, with
    /// the same sentence and the same exit status.
    private static let stepChownTTY: Int32 = 1
    private static let stepDropPrivileges: Int32 = 2
    private static let stepExec: Int32 = 3

    private static func systemMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// True when the child reported a failure; false on EOF, which is what a
    /// successful `execve` looks like from here.
    private static func readReport(
        from descriptor: Int32,
        into buffer: UnsafeMutablePointer<Int32>,
    ) -> Bool {
        let wanted = MemoryLayout<Int32>.size * 2
        var total = 0
        while total < wanted {
            let count = read(
                descriptor,
                UnsafeMutableRawPointer(buffer).advanced(by: total),
                wanted - total,
            )
            if count > 0 {
                total += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        return total == wanted
    }

    private static func describeChildFailure(
        step: Int32,
        code: Int32,
        executable: String,
    ) -> String {
        // The system's reason stays in the sentence (the harness holds this
        // contract): "No such file or directory" versus "Permission denied"
        // is the difference between a typo and a chmod, and the polished
        // copy alone cannot say which.
        switch step {
        case stepExec:
            "Unable to run \(executable) (\(systemMessage(code))). Check the default shell in Settings."
        case stepChownTTY:
            "Unable to set up the terminal for your account (\(systemMessage(code))). Try again."
        default:
            "Unable to start the terminal for your account (\(systemMessage(code))). Try again."
        }
    }

    /// Prepared before `forkpty` so the child only has to call `execve`:
    /// anything else between fork and exec is unsafe in a Swift process.
    private static func makeCStringArray(_ values: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: values.count + 1,
        )
        for (index, value) in values.enumerated() {
            array[index] = strdup(value)
        }
        array[values.count] = nil
        return array
    }

    private static func freeCStringArray(
        _ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        count: Int,
    ) {
        for index in 0 ..< count {
            free(array[index])
        }
        array.deallocate()
    }

    init(
        id: UInt64,
        command: [String],
        environment: [String: String],
        columns: UInt16,
        rows: UInt16,
        credentials: ShellLaunch.Credentials? = nil,
        workingDirectory: String? = nil,
        fallbackWorkingDirectory: String? = nil,
        queue: DispatchQueue,
    ) throws {
        guard let executable = command.first, !executable.isEmpty else {
            throw iGhostVTFailure(
                .spawnFailed,
                "This terminal has no command to run. Check the default shell in Settings.",
            )
        }

        self.id = id
        self.command = command
        self.columns = columns
        self.rows = rows
        self.queue = queue
        foregroundProcessName = (executable as NSString).lastPathComponent

        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let argv = Self.makeCStringArray(command)
        let envp = Self.makeCStringArray(environmentStrings)
        let directory: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap { strdup($0) }
        let fallbackDirectory: UnsafeMutablePointer<CChar>? = fallbackWorkingDirectory.flatMap { strdup($0) }
        let executablePath = strdup(executable)
        defer {
            Self.freeCStringArray(argv, count: command.count)
            Self.freeCStringArray(envp, count: environmentStrings.count)
            free(directory)
            free(fallbackDirectory)
            free(executablePath)
        }

        var size = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        )
        // Prepared before the fork for the same reason the argv is: the child
        // may only make async-signal-safe calls, and building an array is not
        // one of them.
        var supplementaryGroups: [gid_t] = credentials.map { [$0.gid] } ?? []
        var movedToDirectory = false

        // How the child says why it never reached `execve`. The write end is
        // close-on-exec, so a successful exec closes it and the parent simply
        // reads EOF; any other outcome arrives as (step, errno). Without this
        // the only evidence is an exit status of 126 or 127, which cannot say
        // whether the shell was missing, unreadable, or refused.
        var reportDescriptors: [Int32] = [-1, -1]
        guard pipe(&reportDescriptors) == 0 else {
            throw iGhostVTFailure(
                .spawnFailed,
                "Unable to start the terminal. Try again.",
            )
        }
        let reportRead = reportDescriptors[0]
        let reportWrite = reportDescriptors[1]
        _ = fcntl(reportWrite, F_SETFD, FD_CLOEXEC)
        // Allocated before the fork like everything else the child touches.
        let report = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { report.deallocate() }

        var masterDescriptor: Int32 = -1
        let pid = ighostvtForkPTY(&masterDescriptor, nil, nil, &size)
        if pid == 0 {
            // Child: everything below is a bare syscall, and everything it
            // needs was allocated above. `_exit` avoids running the parent's
            // atexit handlers if exec fails.
            close(reportRead)
            // Every daemon descriptor is close-on-exec already (AGENTS.md);
            // the sweep guarantees it for any a future change forgets to
            // mark. The spawn pipe stays until execve closes it.
            let tableSize = getdtablesize()
            var descriptor: Int32 = 3
            while descriptor < tableSize {
                if descriptor != reportWrite {
                    close(descriptor)
                }
                descriptor += 1
            }
            func fail(_ step: Int32) -> Never {
                report[0] = step
                report[1] = errno
                _ = Darwin.write(reportWrite, report, MemoryLayout<Int32>.size * 2)
                _exit(step == Self.stepExec ? 127 : 126)
            }
            if let credentials {
                // The daemon is root and the session must not be. Order
                // matters: once the uid is gone the group changes are no
                // longer permitted. A failure here has to be fatal — execing
                // anyway would hand the user the root shell we just refused.
                if fchown(STDIN_FILENO, credentials.uid, credentials.gid) != 0 {
                    fail(Self.stepChownTTY)
                }
                _ = fchmod(STDIN_FILENO, 0o620)
                if setgroups(1, &supplementaryGroups) != 0 {
                    fail(Self.stepDropPrivileges)
                }
                if setgid(credentials.gid) != 0 {
                    fail(Self.stepDropPrivileges)
                }
                if setuid(credentials.uid) != 0 {
                    fail(Self.stepDropPrivileges)
                }
                // Belt and braces: if the uid did not actually change, refuse.
                if getuid() != credentials.uid || geteuid() != credentials.uid {
                    fail(Self.stepDropPrivileges)
                }
            }
            // After the privilege drop, so the directory has to be reachable
            // by the user the shell will be. An inherited directory the user
            // can no longer enter falls back to the plan's own (the home);
            // only when both refuse does the shell keep the daemon's `/`.
            if let directory {
                movedToDirectory = chdir(directory) == 0
            }
            if !movedToDirectory, let fallbackDirectory {
                _ = chdir(fallbackDirectory)
            }
            // The one disposition this process changed (main.swift), and
            // SIG_IGN survives execve: a verbatim command would otherwise
            // see EPIPE from `yes | head` instead of the exit a terminal
            // gives it. An interactive shell resets it anyway.
            signal(SIGPIPE, SIG_DFL)
            execve(executablePath, argv, envp)
            fail(Self.stepExec)
        }
        close(reportWrite)
        guard pid > 0, masterDescriptor >= 0 else {
            close(reportRead)
            throw iGhostVTFailure(.spawnFailed, "Unable to start the terminal. Try again.")
        }
        // Blocks only until the child execs (EOF) or gives up (8 bytes).
        let reported = Self.readReport(from: reportRead, into: report)
        close(reportRead)
        if reported {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            close(masterDescriptor)
            throw iGhostVTFailure(
                .spawnFailed,
                Self.describeChildFailure(
                    step: report[0],
                    code: report[1],
                    executable: executable,
                ),
            )
        }

        master = masterDescriptor
        childPID = pid
        // A later fork inherits every descriptor the daemon still owns.
        // Closing this master on that child's exec keeps sessions independent:
        // one shell must not retain another session's PTY or spend its fd limit.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
    }

    func start(
        onOutput: @escaping OutputHandler,
        onExit: @escaping ExitHandler,
        onForegroundChange: ForegroundHandler? = nil,
    ) {
        self.onOutput = onOutput
        self.onExit = onExit
        self.onForegroundChange = onForegroundChange

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainAvailableOutput()
        }
        self.readSource = readSource
        readSource.activate()

        let exitSource = DispatchSource.makeProcessSource(
            identifier: childPID,
            eventMask: .exit,
            queue: queue,
        )
        // Polled, not reaped once: XNU's proc_exit posts NOTE_EXIT (what this
        // source is) *before* it marks the process SZOMB and signals SIGCHLD,
        // so a single WNOHANG waitpid here can still see the child running
        // and return 0 — after which nothing would ever try again. The
        // session then looked alive forever while the shell sat there as a
        // zombie; the PTY EOF path masked it whenever the shell was the last
        // process on the terminal, and a background child holding the tty
        // (codex and grok both leave helpers around) was what exposed it.
        exitSource.setEventHandler { [weak self] in
            self?.pollUntilReaped()
        }
        self.exitSource = exitSource
        exitSource.activate()

        let namePoll = DispatchSource.makeTimerSource(queue: queue)
        namePoll.schedule(
            deadline: .now() + Self.processNamePollInterval,
            repeating: Self.processNamePollInterval,
        )
        namePoll.setEventHandler { [weak self] in
            self?.refreshForegroundProcessName()
        }
        processNamePoll = namePoll
        namePoll.activate()

        // A process source registered after its process already died never
        // fires, and a fast child (/bin/echo) can beat the registration. One
        // poll on the queue closes that window — WNOHANG makes it a no-op
        // while the child is still running.
        queue.async { [weak self] in
            self?.reapIfExited()
        }
    }

    /// Bytes typed (or pasted) by the user, forwarded to the shell — all of
    /// them, in the order they were handed over, at the pace the program
    /// reads them.
    ///
    /// Never blocks: the master is non-blocking and this runs on the daemon's
    /// one control queue. Whatever the kernel will not take now waits in
    /// ``pendingInput``.
    ///
    /// Returns false when the session already holds
    /// `sessionPendingInputByteCount` of unread input — the program is not
    /// reading its terminal. Nothing of `data` is queued then: a refusal the
    /// caller can report beats a paste that silently loses its second half.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard isAlive, !data.isEmpty else { return true }
        guard pendingInputByteCount + data.count <= iGhostVTProtocol.sessionPendingInputByteCount else {
            return false
        }
        // The common case — a keystroke, a paste small enough for the
        // kernel — never touches the buffer.
        if pendingInputByteCount == 0 {
            switch data.withUnsafeBytes({ Self.writeAvailable(master, $0) }) {
            case let .wrote(count) where count == data.count:
                return true
            case let .wrote(count):
                pendingInput.append(contentsOf: data[(data.startIndex + count)...])
            case .wouldBlock:
                pendingInput.append(contentsOf: data)
            case .failed:
                // EIO: the slave is closed, the child is on its way out. The
                // exit paths report it; there is nothing to hold for.
                return true
            }
        } else {
            pendingInput.append(contentsOf: data)
        }
        armWriteSource()
        return true
    }

    /// Input accepted but not yet handed to the kernel.
    var pendingInputByteCount: Int {
        pendingInput.count - pendingInputOffset
    }

    private enum WriteOutcome {
        case wrote(Int)
        case wouldBlock
        case failed
    }

    /// One non-blocking write, taking as much as the kernel will accept.
    /// `EAGAIN` with nothing written is `wouldBlock`; a short write is
    /// `wrote`, since XNU only reports `EWOULDBLOCK` when no byte went in.
    private static func writeAvailable(
        _ descriptor: Int32,
        _ buffer: UnsafeRawBufferPointer,
    ) -> WriteOutcome {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return .wrote(0) }
        while true {
            let written = Darwin.write(descriptor, base, buffer.count)
            if written >= 0 {
                return .wrote(written)
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                return .wouldBlock
            default:
                return .failed
            }
        }
    }

    /// The master has room again: push what is pending until it has none.
    private func flushPendingInput() {
        while pendingInputByteCount > 0 {
            let outcome = pendingInput.withUnsafeBytes { bytes in
                Self.writeAvailable(master, UnsafeRawBufferPointer(rebasing: bytes[pendingInputOffset...]))
            }
            switch outcome {
            case let .wrote(count):
                pendingInputOffset += count
            case .wouldBlock:
                compactPendingInput()
                return
            case .failed:
                discardPendingInput()
                return
            }
        }
        discardPendingInput()
    }

    /// Drops the already-written prefix once it outweighs what is left.
    /// Without this the array only resets on a full drain, so a program
    /// reading slowly under continuous input keeps the *logical* backlog
    /// under its cap while the dead prefix grows by every byte ever
    /// drained. Compacting at the halfway mark keeps the array within
    /// twice the live bytes and moves each byte at most once more.
    private func compactPendingInput() {
        guard pendingInputOffset > pendingInput.count - pendingInputOffset else { return }
        pendingInput.removeFirst(pendingInputOffset)
        pendingInputOffset = 0
    }

    private func discardPendingInput() {
        pendingInput.removeAll(
            keepingCapacity: pendingInput.capacity <= Self.retainedInputCapacity,
        )
        pendingInputOffset = 0
        disarmWriteSource()
    }

    private func armWriteSource() {
        guard !isWriteArmed else { return }
        if let writeSource {
            writeSource.resume()
            isWriteArmed = true
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            self?.flushPendingInput()
        }
        // Created suspended by libdispatch; `activate` counts as the first
        // resume, so the arm/disarm pair below stays balanced.
        writeSource = source
        isWriteArmed = true
        source.activate()
    }

    private func disarmWriteSource() {
        guard isWriteArmed else { return }
        writeSource?.suspend()
        isWriteArmed = false
    }

    /// Stops feeding the PTY. Resumed before it is cancelled — releasing a
    /// suspended dispatch object is a crash — and the buffer goes with it.
    private func stopWriting() {
        pendingInput = []
        pendingInputOffset = 0
        guard let writeSource else { return }
        if !isWriteArmed {
            writeSource.resume()
            isWriteArmed = true
        }
        writeSource.cancel()
        self.writeSource = nil
        isWriteArmed = false
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard isAlive else { return }
        self.columns = columns
        self.rows = rows
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Everything the daemon has buffered for this session, oldest first.
    func replayData() -> Data {
        replayBuffer
    }

    /// Stops or resumes draining the PTY. Idempotent; the source is
    /// suspended at most once, and resumed before it is ever cancelled
    /// (releasing a suspended dispatch object is a crash).
    func setOutputPaused(_ paused: Bool) {
        guard paused != isOutputPaused else { return }
        isOutputPaused = paused
        guard let readSource else { return }
        if paused {
            readSource.suspend()
        } else {
            readSource.resume()
        }
    }

    private func stopReading() {
        guard let readSource else { return }
        if isOutputPaused {
            readSource.resume()
            isOutputPaused = false
        }
        readSource.cancel()
        self.readSource = nil
    }

    func terminate() {
        guard isAlive else { return }
        kill(childPID, SIGHUP)
    }

    func invalidate() {
        stopReading()
        stopWriting()
        exitSource?.cancel()
        exitSource = nil
        processNamePoll?.cancel()
        processNamePoll = nil
        onOutput = nil
        onExit = nil
        onForegroundChange = nil
        // Released here rather than left to deinit: this is what the daemon
        // is holding per session, and a caller may keep the object alive a
        // little longer than the session it stands for.
        replayBuffer = Data()
        if isAlive {
            kill(childPID, SIGKILL)
            isAlive = false
            // Reaped so the child does not linger as a zombie: the process
            // source is already cancelled, so nothing else ever will, and
            // leaked process-table entries are their own kind of growth.
            //
            // Never with a blocking wait, though. This runs on the daemon's
            // one control queue, and a blocking `waitpid` here once froze
            // the entire daemon — listener and all — when the grace-kill
            // path met a child the kernel was slow to end. WNOHANG polling
            // keeps the queue alive no matter what the child does.
            Self.reapWithoutBlocking(childPID, on: queue)
        }
        close(master)
    }

    /// WNOHANG-polls the killed child off the queue instead of blocking on
    /// it. Gives up after ~5s; a zombie then is the kernel's problem, not a
    /// deaf daemon.
    private static func reapWithoutBlocking(
        _ pid: pid_t,
        on queue: DispatchQueue,
        attempt: Int = 0,
    ) {
        var status: Int32 = 0
        guard waitNoHang(pid, status: &status) == 0 else { return }
        guard attempt < 25 else {
            DaemonFileLog.log("child \(pid) not reapable after SIGKILL, leaving it")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) {
            reapWithoutBlocking(pid, on: queue, attempt: attempt + 1)
        }
    }

    // MARK: - Internals

    private var hasLoggedFirstOutput = false

    private func drainAvailableOutput() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { destination -> Int in
                guard let base = destination.baseAddress else { return -1 }
                return read(master, base, destination.count)
            }
            if count > 0 {
                let data = Data(buffer[0 ..< count])
                if !hasLoggedFirstOutput {
                    hasLoggedFirstOutput = true
                    DaemonFileLog.log("session \(id) first output, \(count) byte(s)")
                }
                append(data)
                onOutput?(id, data)
                // Output is the moment the foreground is most likely to
                // have just changed (a command echoed, a TUI's first draw).
                refreshForegroundProcessNameIfDue()
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count == 0 {
                // EOF: the child closed the terminal. The process source
                // usually reports the status, but a fast child (/bin/echo)
                // can slip past both it and the one-shot poll in `start` —
                // seen on CI as an exit that never arrives. EOF is this
                // session's own proof the child is going, so poll it reaped.
                stopReading()
                pollUntilReaped()
            }
            return
        }
    }

    private func append(_ data: Data) {
        replayBuffer.append(data)
        let excess = replayBuffer.count - iGhostVTProtocol.sessionReplayByteCount
        if excess > 0 {
            replayBuffer.removeFirst(excess)
        }
    }

    /// The drain's entry point: refreshes at most every
    /// ``processNameDrainInterval``, so a session printing at full speed
    /// costs the same as an idle one. The timer covers whatever this skips.
    private func refreshForegroundProcessNameIfDue() {
        let now = DispatchTime.now()
        let elapsed = now.uptimeNanoseconds &- lastProcessNameCheck.uptimeNanoseconds
        guard elapsed >= Self.processNameDrainInterval else { return }
        lastProcessNameCheck = now
        refreshForegroundProcessName()
    }

    /// Re-reads which process group is in the foreground on this terminal
    /// and reports its leader's name, whether it is the shell, and the
    /// shell's directory, when any of the three changed. `tcgetpgrp` on the
    /// master asks the kernel, so the shell's job control is the source of
    /// truth. A leader already gone (`proc_name` returns 0) keeps the last
    /// name until the next change lands — but the shell flag is still
    /// updated from it: a pipeline's group is led by its first command
    /// (`cat file | vim -`), which the shell reaps at once while the rest
    /// runs, and the flag is what says something is running. A nested shell
    /// (`zsh` typed into zsh) keeps the name the same way.
    private func refreshForegroundProcessName() {
        guard isAlive else { return }
        let processGroup = tcgetpgrp(master)
        guard processGroup > 0 else { return }
        let isShell = processGroup == childPID
        var buffer = [CChar](repeating: 0, count: 128)
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return ighostvtProcName(processGroup, base, UInt32(raw.count))
        }
        var name = foregroundProcessName
        if length > 0 {
            let resolved = buffer.withUnsafeBufferPointer { pointer -> String in
                guard let base = pointer.baseAddress else { return "" }
                return String(cString: base)
            }
            if !resolved.isEmpty {
                name = resolved
            }
        }
        // The shell taking the terminal back is when a `cd` is likeliest to
        // have just happened, so that transition always re-reads; a `cd`
        // typed at the prompt changes no process at all and is caught by
        // the interval instead.
        let returnedToPrompt = isShell && !isForegroundShell
        let movedDirectory = refreshDirectory(isShellInForeground: isShell, force: returnedToPrompt)
        guard name != foregroundProcessName || isShell != isForegroundShell || movedDirectory else {
            return
        }
        foregroundProcessName = name
        isForegroundShell = isShell
        onForegroundChange?(self)
    }

    /// Re-reads the shell's directory when it is due (or when the caller
    /// knows it is worth it), and answers whether it moved. Skipped
    /// entirely while a program is in front of the shell: the shell is not
    /// running, so its directory cannot change.
    private func refreshDirectory(isShellInForeground: Bool, force: Bool) -> Bool {
        guard isShellInForeground else { return false }
        let now = DispatchTime.now()
        let elapsed = now.uptimeNanoseconds &- lastDirectoryCheck.uptimeNanoseconds
        guard force || elapsed >= Self.directoryPollInterval else { return false }
        lastDirectoryCheck = now
        let directory = currentDirectory
        guard let directory, directory != reportedDirectory else { return false }
        reportedDirectory = directory
        return true
    }

    /// The spawned program's current directory, as the kernel spells it —
    /// what another session's `chdir` wants, whatever vocabulary the shell
    /// speaks (under roothide a vroot-linked shell prints its `$PWD` with
    /// the jbroot stripped). Asked of the shell itself, not the foreground
    /// program: a `:cd` inside vim is vim's business, and the directory a
    /// user thinks of as the tab's is the one the prompt will return to.
    /// `nil` once the child is gone or when the kernel refuses.
    var currentDirectory: String? {
        guard isAlive else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: ProcVnodePathInfo.size,
            alignment: MemoryLayout<UInt64>.alignment,
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: ProcVnodePathInfo.size)
        let filled = ighostvtProcPIDInfo(
            childPID,
            ProcVnodePathInfo.flavor,
            0,
            buffer,
            Int32(ProcVnodePathInfo.size),
        )
        guard filled == Int32(ProcVnodePathInfo.size) else { return nil }
        let pathStart = buffer.advanced(by: ProcVnodePathInfo.currentDirectoryPathOffset)
        // Bounded: the kernel NUL-terminates, but never trust a struct copy
        // to keep doing so.
        let bytes = UnsafeRawBufferPointer(start: pathStart, count: ProcVnodePathInfo.pathLength)
        let length = bytes.firstIndex(of: 0) ?? ProcVnodePathInfo.pathLength
        let path = String(decoding: bytes.prefix(length), as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    /// WNOHANG-polls until the child is reaped, bounded at half a second:
    /// started on evidence the child is going (the exit source, or EOF on
    /// the PTY), it covers the gap before the kernel makes it waitable.
    private func pollUntilReaped(attempt: Int = 0) {
        guard isAlive else { return }
        reapIfExited()
        guard isAlive else { return }
        guard attempt < 25 else {
            // Not a failure: a large child can spend longer than this in
            // teardown between its exit notice and SZOMB. The registry's
            // SIGCHLD sweep reaps it when the kernel is done.
            DaemonFileLog.log(
                "session \(id) child \(childPID) not reapable 500ms after its exit notice; leaving it to SIGCHLD",
            )
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            self?.pollUntilReaped(attempt: attempt + 1)
        }
    }

    /// Reaps the child if it has exited; a cheap no-op while it runs, so the
    /// registry's SIGCHLD sweep can ask every session — the signal coalesces
    /// and names no pid.
    func reapIfExited() {
        guard isAlive else { return }
        var status: Int32 = 0
        let result = Self.waitNoHang(childPID, status: &status)
        // 0: still running, or exited but not yet SZOMB — try again later.
        // ECHILD: nothing to wait for; the child is gone whatever reaped it.
        guard result != 0 else { return }
        isAlive = false

        let exitCode: Int32 = if result < 0 {
            -1
        } else if status & 0x7F == 0 {
            (status >> 8) & 0xFF
        } else {
            128 + (status & 0x7F)
        }

        // Let any output written just before exit reach the client first.
        drainAvailableOutput()
        onExit?(id, exitCode)
    }

    /// `waitpid(WNOHANG)` retried through EINTR: the pid once reaped, 0 while
    /// the child runs (or has exited but is not yet SZOMB), -1 with ECHILD
    /// when something else reaped it.
    private static func waitNoHang(_ pid: pid_t, status: inout Int32) -> pid_t {
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result < 0, errno == EINTR {
                continue
            }
            return result
        }
    }

    deinit {
        stopReading()
        exitSource?.cancel()
        processNamePoll?.cancel()
    }
}
