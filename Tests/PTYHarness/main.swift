import Darwin
import Dispatch
import Foundation

// Exercises the daemon's spawn path on macOS, where the mach service and
// launchd are out of reach but `forkpty`/`execve`, the read loop, the exit
// decoding, and `TIOCSWINSZ` behave the same as on the device. This is the
// part of the daemon a device test would be worst at debugging, so it gets
// covered here first.

let harnessQueue = DispatchQueue(label: "wiki.qaq.ighostvt.harness")
var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

/// Runs a session to completion, returning everything it printed and how it
/// exited. `input` is written once the session is running.
func run(
    command: [String],
    input: String? = nil,
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    resizeTo: (columns: UInt16, rows: UInt16)? = nil,
    credentials: ShellLaunch.Credentials? = nil,
    workingDirectory: String? = nil,
    fallbackWorkingDirectory: String? = nil,
    timeout: TimeInterval = 10
) -> (output: String, exitCode: Int32?, session: PTYSession)? {
    let session: PTYSession
    do {
        session = try PTYSession(
            id: 1,
            command: command,
            environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            columns: columns,
            rows: rows,
            credentials: credentials,
            workingDirectory: workingDirectory,
            fallbackWorkingDirectory: fallbackWorkingDirectory,
            queue: harnessQueue
        )
    } catch {
        return nil
    }

    let lock = NSLock()
    var collected = Data()
    var exitCode: Int32?
    let finished = DispatchSemaphore(value: 0)

    session.start(
        onOutput: { _, data in
            lock.lock()
            collected.append(data)
            lock.unlock()
        },
        onExit: { _, code in
            lock.lock()
            exitCode = code
            lock.unlock()
            finished.signal()
        }
    )

    if let resizeTo {
        // Let the child settle so it observes the change rather than racing
        // its own startup.
        Thread.sleep(forTimeInterval: 0.3)
        session.resize(columns: resizeTo.columns, rows: resizeTo.rows)
    }
    if let input {
        Thread.sleep(forTimeInterval: 0.3)
        session.write(Data(input.utf8))
    }

    _ = finished.wait(timeout: .now() + timeout)
    lock.lock()
    let output = String(decoding: collected, as: UTF8.self)
    let code = exitCode
    lock.unlock()
    return (output, code, session)
}

func shellPath() -> String {
    for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"] where access(candidate, X_OK) == 0 {
        return candidate
    }
    return "/bin/sh"
}

print("PTY harness")

print("spawn and capture output")
if let result = run(command: ["/bin/echo", "hello-from-ighostvt"]) {
    check(result.output.contains("hello-from-ighostvt"), "child stdout reaches the host")
    check(result.exitCode == 0, "clean exit reports 0 (got \(String(describing: result.exitCode)))")
} else {
    check(false, "spawning /bin/echo succeeded")
}

// A terminal opens in the user's home, not wherever launchd started the
// daemon; a home that is not there is not used.
print("working directory")
if let result = run(command: ["/bin/sh", "-c", "pwd"], workingDirectory: "/private/tmp") {
    check(result.output.contains("/private/tmp"), "the child starts in the working directory")
} else {
    check(false, "spawning a shell with a working directory succeeded")
}

if let plan = ShellLaunch.plan(requestedShell: nil) {
    check(
        plan.workingDirectory == NSHomeDirectory(),
        "the default plan starts a session in the session user's home (got \(String(describing: plan.workingDirectory)))"
    )
}

// An inherited directory the session user cannot enter falls back to the
// plan's own, never to the daemon's `/`.
if let result = run(
    command: ["/bin/sh", "-c", "pwd"],
    workingDirectory: "/nonexistent/ighostvt-harness",
    fallbackWorkingDirectory: "/private/tmp"
) {
    check(result.output.contains("/private/tmp"), "a working directory that refuses falls back to the plan's own")
} else {
    check(false, "spawning a shell with a fallback working directory succeeded")
}

let homelessUser = PasswdEntry(name: "nobody", uid: 0, gid: 0, home: "/nonexistent/ighostvt-harness", shell: "/bin/sh")
check(ShellLaunch.workingDirectory(for: homelessUser) == nil, "a home that does not exist is skipped")

print("exit status decoding")
if let result = run(command: ["/bin/sh", "-c", "exit 7"]) {
    check(result.exitCode == 7, "non-zero exit is decoded (got \(String(describing: result.exitCode)))")
} else {
    check(false, "spawning /bin/sh succeeded")
}

print("signal death")
if let result = run(command: ["/bin/sh", "-c", "kill -TERM $$"]) {
    check(
        result.exitCode == 128 + 15,
        "a signalled child reports 128+signal (got \(String(describing: result.exitCode)))"
    )
} else {
    check(false, "spawning a self-terminating shell succeeded")
}

print("input reaches the child")
if let result = run(command: ["/bin/sh", "-c", "read line; echo GOT:$line"], input: "ping\n") {
    check(result.output.contains("GOT:ping"), "bytes written to the PTY are read by the child")
} else {
    check(false, "spawning a reading shell succeeded")
}

// A paste is one write of far more than a PTY master will take: XNU accepts
// about `TTYHOG - 2` (~1022) bytes ahead of the program reading the terminal
// and answers EAGAIN for the rest. That tail used to be dropped on the floor
// — a 13 KB paste reached the shell as its first kilobyte, cut mid-character.
// It must now arrive whole, in order, however slowly the program reads.
print("a large write is not truncated")
do {
    let payload = (1 ... 400)
        .map { String(format: "L%04d 中文　全角空格　abcdefghijklmnopqrstuvwxyz0123456789", $0) }
        .joined(separator: "\n") + "\n"
    let bytes = Array(payload.utf8)
    check(bytes.count > 20 * 1024, "the payload is far past one PTY buffer (\(bytes.count) bytes)")
    let session = try PTYSession(
        id: 7,
        // Raw mode: no line editing on the way in and no LF → CRLF on the
        // way out, so what comes back is exactly what went in. `cat` reads
        // it a chunk at a time, which is what makes the master fill up in
        // the first place.
        command: ["/bin/sh", "-c", "stty raw -echo; exec cat"],
        environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    let echoLock = NSLock()
    var echoed = Data()
    session.start(
        onOutput: { _, data in
            echoLock.lock()
            echoed.append(data)
            echoLock.unlock()
        },
        onExit: { _, _ in }
    )
    Thread.sleep(forTimeInterval: 0.4)
    check(harnessQueue.sync { session.write(Data(bytes)) }, "the write is accepted")
    // Chunked exactly as a client sends it, straight after, with no pause:
    // the second write must queue behind the first, not race past it.
    let tail = Array("TAIL-MARKER\n".utf8)
    check(harnessQueue.sync { session.write(Data(tail)) }, "a write queued behind it is accepted too")
    let deadline = Date().addingTimeInterval(20)
    var settled = Data()
    while Date() < deadline {
        echoLock.lock()
        settled = echoed
        echoLock.unlock()
        if settled.count >= bytes.count + tail.count {
            break
        }
        usleep(50000)
    }
    check(
        settled.count == bytes.count + tail.count,
        "every byte written comes back (\(settled.count) of \(bytes.count + tail.count))"
    )
    check(
        Array(settled.prefix(bytes.count)) == bytes,
        "and in the order it was written, byte for byte"
    )
    check(
        Array(settled.suffix(tail.count)) == tail,
        "with the write that followed it landing after, not interleaved"
    )
    check(
        String(decoding: settled, as: UTF8.self).contains("L0400 中文"),
        "the last line survives, multibyte characters intact"
    )
    check(harnessQueue.sync { session.pendingInputByteCount } == 0, "nothing is left pending once it is all in")
    harnessQueue.sync { session.invalidate() }
} catch {
    check(false, "a session for the large write spawns (\(error))")
}

// The bound on that buffer: a program that never reads its terminal cannot
// make the daemon hold input without limit. The request past the cap is
// refused whole — the caller is told, rather than half the paste vanishing.
print("input for a program that never reads is bounded")
do {
    let session = try PTYSession(
        id: 8,
        command: ["/bin/sh", "-c", "stty raw -echo; exec sleep 30"],
        environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    session.start(onOutput: { _, _ in }, onExit: { _, _ in })
    Thread.sleep(forTimeInterval: 0.4)
    let chunk = Data(repeating: UInt8(ascii: "x"), count: iGhostVTProtocol.inputChunkByteCount)
    var accepted = 0
    var refused = false
    for _ in 0 ..< 32 {
        if harnessQueue.sync(execute: { session.write(chunk) }) {
            accepted += 1
        } else {
            refused = true
            break
        }
    }
    check(refused, "a session whose program never reads eventually refuses more input")
    let held = harnessQueue.sync { session.pendingInputByteCount }
    check(
        held <= iGhostVTProtocol.sessionPendingInputByteCount,
        "and holds no more than its cap (\(held) bytes after \(accepted) chunks)"
    )
    harnessQueue.sync { session.invalidate() }
    check(harnessQueue.sync { session.pendingInputByteCount } == 0, "invalidating releases the pending input")
} catch {
    check(false, "a session for the backlog test spawns (\(error))")
}

print("window size")
if let result = run(
    command: [shellPath(), "-c", "sleep 0.6; stty size"],
    columns: 80,
    rows: 24,
    resizeTo: (columns: 100, rows: 40)
) {
    // `stty size` prints "rows cols".
    check(
        result.output.contains("40 100"),
        "TIOCSWINSZ reaches the child (stty size said: \(result.output.split(separator: "\n").last.map(String.init) ?? "nothing"))"
    )
} else {
    check(false, "spawning a shell for stty succeeded")
}

print("initial window size")
if let result = run(command: [shellPath(), "-c", "stty size"], columns: 132, rows: 43) {
    check(result.output.contains("43 132"), "the size passed to forkpty is the child's initial size")
} else {
    check(false, "spawning a shell for the initial stty succeeded")
}

print("replay buffer")
if let result = run(command: ["/bin/echo", "replay-me"]) {
    let replay = String(decoding: result.session.replayData(), as: UTF8.self)
    check(replay.contains("replay-me"), "output is retained for reattaching clients")
    result.session.invalidate()
}

// The replay buffer is the daemon's only per-session accumulation, so it is
// the one thing that could grow without bound while a session runs.
print("replay buffer is capped")
let flood = iGhostVTProtocol.sessionReplayByteCount * 3
if let result = run(
    command: ["/bin/sh", "-c", "dd if=/dev/zero bs=1024 count=\(flood / 1024) 2>/dev/null | tr '\\0' 'x'"],
    timeout: 30
) {
    let retained = result.session.replayData().count
    check(
        retained <= iGhostVTProtocol.sessionReplayByteCount,
        "a session that printed \(flood / 1024) KiB retains at most \(iGhostVTProtocol.sessionReplayByteCount / 1024) KiB (kept \(retained / 1024) KiB)"
    )
    check(
        retained > iGhostVTProtocol.sessionReplayByteCount / 2,
        "and it keeps the most recent output rather than discarding everything"
    )
    result.session.invalidate()
    check(
        result.session.replayData().isEmpty,
        "invalidating a session releases the buffer instead of waiting for deinit"
    )
} else {
    check(false, "spawning a shell that floods the buffer succeeded")
}

// A shell inherits every descriptor that survives execve. With another
// session alive — its PTY master, the spawn pipe, the dispatch sources'
// kqueue — a new shell must still see nothing beyond its own terminal:
// anything else is a leaked handle on another session, and a hole in the
// per-process fd budget tools like codex burn through.
print("descriptors do not leak into the child")
do {
    let bystander = try PTYSession(
        id: 4,
        command: ["/bin/sh", "-c", "sleep 5"],
        environment: ["PATH": "/usr/bin:/bin"],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    bystander.start(onOutput: { _, _ in }, onExit: { _, _ in })
    Thread.sleep(forTimeInterval: 0.2)
    // The shell lists its own table: `ls /dev/fd` would add the descriptors
    // `ls` opens for the listing itself. The trailing `:` keeps sh from
    // exec-ing lsof in place, which would make `$$` lsof and list its pipes.
    if let result = run(command: ["/bin/sh", "-c", "/usr/sbin/lsof -p $$ -a -d 0-1024; :"], timeout: 20) {
        // The PTY turns every newline into "\r\n", one Character in Swift.
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        // lsof rows: COMMAND PID USER FD TYPE ...; FD is "0u", "3r", "cwd"...
        let descriptors = lines.dropFirst().compactMap { line -> Int? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 3 else { return nil }
            return Int(columns[3].prefix { $0.isNumber })
        }
        check(
            descriptors.sorted() == [0, 1, 2],
            "a child holds nothing beyond its terminal (saw \(descriptors.sorted()))"
        )
        result.session.invalidate()
    } else {
        check(false, "spawning a shell to list its descriptors succeeded")
    }
    bystander.invalidate()
} catch {
    check(false, "spawning the bystander session succeeded")
}

// The NOTE_EXIT race (see PTYSession.start): a background child keeping the
// tty open is the case that exposed it — the exit must still arrive
// promptly, not when the straggler finally lets go.
print("exit is reported while a background child holds the terminal")
let holdStart = Date()
if let result = run(command: ["/bin/sh", "-c", "sleep 4 & exit 5"], timeout: 6) {
    let elapsed = Date().timeIntervalSince(holdStart)
    check(result.exitCode == 5, "the shell's own status is reported (got \(String(describing: result.exitCode)))")
    check(elapsed < 2, "and it arrives before the straggler exits (took \(String(format: "%.2f", elapsed))s)")
    result.session.invalidate()
} else {
    check(false, "spawning a shell with a background child succeeded")
}

// `ighostvtd-io` ignores SIGPIPE for itself, and SIG_IGN survives execve: a
// verbatim command (no interactive shell to reset it) would see EPIPE where
// a terminal kills the writer silently. The harness takes the io side's
// disposition here to prove the child does not inherit it.
print("SIGPIPE is at default in the child")
signal(SIGPIPE, SIG_IGN)
if let result = run(command: ["/bin/sh", "-c", "yes | head -c 1 >/dev/null; echo pipe-done"]) {
    check(result.output.contains("pipe-done"), "the pipeline completes")
    check(
        !result.output.contains("Broken pipe"),
        "and the writer dies of SIGPIPE instead of reporting EPIPE (output: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))"
    )
    result.session.invalidate()
} else {
    check(false, "spawning a pipeline succeeded")
}

print("rejecting a bad command")
do {
    _ = try PTYSession(
        id: 2,
        command: [],
        environment: [:],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    check(false, "an empty command is rejected")
} catch {
    check(true, "an empty command is rejected")
}

// A child that never reaches execve reports why through the spawn pipe, so
// the app can show the real reason instead of "no usable shell was found".
print("spawn failures explain themselves")
for (command, expected) in [
    (["/bin/nope-not-here"], "No such file"),
    (["/etc"], "Permission denied"),
] {
    do {
        _ = try PTYSession(
            id: 3,
            command: command,
            environment: [:],
            columns: 80,
            rows: 24,
            queue: harnessQueue
        )
        check(false, "spawning \(command[0]) fails")
    } catch let failure as iGhostVTFailure {
        check(
            failure.code == .spawnFailed
                && failure.message.contains(command[0])
                && failure.message.contains(expected),
            "\(command[0]) reports the real errno (said: \(failure.message))"
        )
    } catch {
        check(false, "spawning \(command[0]) throws iGhostVTFailure, not \(error)")
    }
}

print("bootstrap path resolution")
// The harness does not run from /usr/libexec/ighostvtd, so no bootstrap is
// found and every mapping degrades to identity — the same stub behaviour
// roothide's own API has on a rootful system.
check(RuntimeEnvironment.bootstrap == .none, "no bootstrap is detected off-device")
check(
    RuntimeEnvironment.resolve("/bin/sh") == "/bin/sh",
    "resolution is identity without a bootstrap"
)
check(
    RuntimeEnvironment.bootstrapPath("/bin/sh") == "/bin/sh",
    "and so is the bootstrap's own spelling"
)
check(
    RuntimeEnvironment.systemPath("/bin/sh") == "/bin/sh",
    "and so is the system's"
)

// Only one layout is ever live on a given device, so exercise each one's three
// vocabularies directly. Mixing them up is the bug this type exists to prevent.
let jbroot = "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
let roothide = RuntimeEnvironment.Bootstrap.roothide(jbroot: jbroot)
check(
    roothide.bootstrapPath("/bin/zsh") == "/bin/zsh",
    "roothide leaves the bootstrap's own paths unprefixed — vroot resolves them"
)
check(
    roothide.resolve("/bin/zsh") == "\(jbroot)/bin/zsh",
    "but the kernel is handed the jbroot-prefixed path"
)
check(
    roothide.systemPath("/usr/bin") == "/rootfs/usr/bin",
    "and iOS's own filesystem is reached through the jbroot's /rootfs bridge"
)

let rootless = RuntimeEnvironment.Bootstrap.rootless(prefix: "/var/jb")
check(
    rootless.bootstrapPath("/bin/zsh") == "/var/jb/bin/zsh",
    "rootless prefixes the bootstrap's own paths — its binaries have /var/jb compiled in"
)
check(
    rootless.resolve("/var/jb/bin/zsh") == "/var/jb/bin/zsh",
    "so they are already what the kernel wants"
)
check(
    rootless.systemPath("/usr/bin") == "/usr/bin",
    "and iOS's own filesystem is just itself"
)
check(RuntimeEnvironment.isExecutable("/bin/sh"), "an existing shell is seen as executable")
check(!RuntimeEnvironment.isExecutable("/bin/nope-not-here"), "a missing shell is not")
check(!RuntimeEnvironment.isExecutable("/etc"), "a directory is not executable")

print("shell launch planning")
if let plan = ShellLaunch.plan(requestedShell: nil) {
    check(plan.command.first?.hasPrefix("/") == true, "the default plan execs an absolute path")
    check(plan.environment["TERM"] == "xterm-256color", "TERM is set")
    check(plan.environment["TERM_PROGRAM"] == "iGhostVT", "TERM_PROGRAM identifies the app")
    // Naming a locale the system cannot load is worse than naming none:
    // setlocale fails and everything silently falls back to C, which is where
    // multibyte input starts drawing one byte at a time.
    let ctype = plan.environment["LC_CTYPE"] ?? ""
    check(ctype.hasSuffix("UTF-8"), "LC_CTYPE selects a UTF-8 locale (got '\(ctype)')")
    check(
        FileManager.default.fileExists(atPath: "/usr/share/locale/\(ctype)/LC_CTYPE"),
        "the exported LC_CTYPE names a locale this system can actually load"
    )
    // LANG and LC_ALL set every category at once; on iOS only LC_CTYPE has
    // data, so either of them fails and takes the whole process back to C.
    check(plan.environment["LANG"] == nil, "LANG is left alone — it would set every category")
    check(plan.environment["LC_ALL"] == nil, "LC_ALL is left alone for the same reason")
    // Sessions are always spawned directly — `login` is off the table because
    // Procursus's pam_launchd.so moves the session into a bootstrap namespace
    // that cannot reach mDNSResponder, killing DNS (see ShellLaunch.plan).
    check(
        plan.command.first?.hasSuffix("/login") != true,
        "the default plan never routes through login — pam_launchd would cost the session its DNS"
    )
    check(plan.environment["PATH"] != nil, "a directly spawned shell is given a PATH")
    check(plan.environment["USER"] != nil, "a directly spawned shell is told who it is")
    check(plan.environment["HOME"] != nil, "a directly spawned shell is given a HOME")
} else {
    check(false, "a default plan is produced")
}

print("shell integration")
/// Nothing is injected when the scripts are not installed — the harness host
/// has no /usr/share/ighostvt, which is also the state of a device where the
/// package predates them. A stray `--posix` here would start every bash
/// session in a mode its rc files are not written for.
var integrationEnvironment: [String: String] = ["HOME": "/tmp"]
check(
    ShellIntegration.apply(shell: "/bin/bash", to: &integrationEnvironment).isEmpty,
    "no scripts on disk means no arguments are added"
)
check(
    integrationEnvironment == ["HOME": "/tmp"],
    "no scripts on disk means the environment is left alone"
)
/// `sh` is not a shell anyone ships an integration for, and pointing it at
/// another shell's rc files is how a session ends up printing syntax errors
/// before its first prompt.
var shEnvironment: [String: String] = [:]
check(
    ShellIntegration.apply(shell: "/bin/sh", to: &shEnvironment).isEmpty && shEnvironment.isEmpty,
    "sh is left untouched"
)

if let plan = ShellLaunch.plan(requestedShell: "/bin/sh") {
    check(plan.command == ["/bin/sh", "-il"], "an explicit shell is spawned as a login shell")
    let directories = (plan.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    check(directories.contains("/usr/bin"), "PATH reaches the system's own tools")
    check(
        directories.allSatisfy { !$0.hasPrefix("/var/jb") && !$0.hasPrefix("/rootfs") },
        "with no bootstrap, PATH assumes no prefixed layout"
    )
    check(
        Set(directories).count == directories.count,
        "the bootstrap and system halves collapse into one another without duplicates"
    )
} else {
    check(false, "an explicit shell produces a plan")
}

// A caller's argv runs in the terminal's environment, not an empty one: a
// curses program with no TERM exits at initscr(), and the CLI has printed
// the session id by then. Only the shell integration stays off.
let verbatim = ShellLaunch.verbatimPlan(command: ["/usr/bin/env"])
check(verbatim.command == ["/usr/bin/env"], "a verbatim plan runs the argv as given")
check(verbatim.environment["TERM"] == "xterm-256color", "a verbatim command is given a TERM")
check(verbatim.environment["LC_CTYPE"]?.hasSuffix("UTF-8") == true, "and a UTF-8 LC_CTYPE")
check(verbatim.environment["PATH"] != nil, "and a PATH")
check(verbatim.environment["HOME"] != nil && verbatim.environment["USER"] != nil, "and knows whose session it is")
check(verbatim.environment["SHELL"]?.hasPrefix("/") == true, "and which shell the user has")
check(
    verbatim.environment["ZDOTDIR"] == nil && verbatim.environment["ENV"] == nil
        && verbatim.environment["GHOSTTY_BASH_INJECT"] == nil,
    "with no shell integration, which needs an argv of its own"
)

check(ShellLaunch.plan(requestedShell: "/bin/nope-not-here") == nil, "a missing shell is rejected")
check(ShellLaunch.plan(requestedShell: "bin/sh") == nil, "a relative shell path is rejected")
check(ShellLaunch.validate(["/bin/echo", "hi"]) != nil, "an absolute argv is accepted")
check(ShellLaunch.validate(["echo", "hi"]) == nil, "a relative argv is rejected")
check(
    ShellLaunch.validate(["/bin/echo"] + Array(repeating: "x", count: 200)) == nil,
    "an over-long argv is rejected"
)

print("passwd lookup")
if let entry = PasswdEntry.forCurrentUser() {
    check(entry.uid == getuid(), "the current user is found")
    check(entry.shell.hasPrefix("/"), "the passwd shell is an absolute path")
} else {
    check(false, "the current user is found")
}

// By name, from the passwd *file* — the daemon looks `mobile` up this way
// because libc answers from the system database, which on the device is the
// iOS one and has no bootstrap users in it. `root` is the one name present in
// the file on both the device and the host.
if let root = PasswdEntry.forUser(name: "root") {
    check(root.uid == 0 && root.gid == 0, "a user is findable by name in the passwd file")
    check(root.shell.hasPrefix("/"), "the named user's shell is an absolute path")
} else {
    check(false, "a user is findable by name in the passwd file")
}

print("privilege drop")
// The daemon runs as root and its sessions must not: only root can change
// uid, so an unprivileged harness asserts the planner refuses to try, and a
// root one asserts the child really lands on the target user.
if getuid() == 0 {
    // `mobile` on the device; on the host, any unprivileged user the passwd
    // file actually lists (macOS keeps normal users in DirectoryService, and
    // `nobody`'s negative uid does not survive parsing as a uid_t).
    let target = PasswdEntry.forUser(name: "mobile")
        ?? PasswdEntry.forUser(name: "daemon")
    if let target {
        let credentials = ShellLaunch.Credentials(uid: target.uid, gid: target.gid)
        check(
            ShellLaunch.credentials(for: target) == credentials,
            "root drops to the session user"
        )
        if let result = run(command: ["/usr/bin/id", "-u"], credentials: credentials) {
            check(
                result.output.contains("\(target.uid)"),
                "the child execs as uid \(target.uid) (id said: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))"
            )
            result.session.invalidate()
        } else {
            check(false, "a privilege-dropping session spawns")
        }
    }
} else {
    check(
        ShellLaunch.credentials(for: PasswdEntry.forCurrentUser()) == nil,
        "a non-root daemon drops nothing — setuid would only fail"
    )
}

// A new tab opens where the current one's shell is. The daemon asks the
// kernel for the shell's directory rather than trusting the shell's own
// report, so it works for a shell with no OSC 7 and yields the path in the
// spelling `chdir` wants.
print("inherited working directory")
do {
    // The registry has no lock of its own — it lives on the io side's one
    // control queue, where its exit handlers run — so every call hops there.
    let registry = SessionRegistry(queue: harnessQueue)
    // `exec` keeps the pid: the directory read is the spawned child's.
    let source = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "cd /private/tmp && exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24
        )
    }
    var sourceDirectory: String?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        sourceDirectory = source.currentDirectory
        if sourceDirectory == "/private/tmp" {
            break
        }
        usleep(50000)
    }
    check(
        sourceDirectory == "/private/tmp",
        "a live session's current directory is read from the kernel (got \(String(describing: sourceDirectory)))"
    )
    check(
        harnessQueue.sync { registry.inheritableDirectory(from: source.id) } == "/private/tmp",
        "the registry offers a live session's directory"
    )
    check(
        harnessQueue.sync { registry.inheritableDirectory(from: source.id &+ 1000) } == nil,
        "an unknown session offers nothing"
    )

    let inherited = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24,
            inheritDirectoryFrom: source.id
        )
    }
    var inheritedDirectory: String?
    let inheritedDeadline = Date().addingTimeInterval(5)
    while Date() < inheritedDeadline {
        inheritedDirectory = inherited.currentDirectory
        if inheritedDirectory == "/private/tmp" {
            break
        }
        usleep(50000)
    }
    check(
        inheritedDirectory == "/private/tmp",
        "a session opened from another starts in its directory (got \(String(describing: inheritedDirectory)))"
    )

    let fresh = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24,
            inheritDirectoryFrom: source.id &+ 1000
        )
    }
    var freshDirectory: String?
    let freshDeadline = Date().addingTimeInterval(5)
    while Date() < freshDeadline {
        freshDirectory = fresh.currentDirectory
        if freshDirectory == NSHomeDirectory() {
            break
        }
        usleep(50000)
    }
    check(
        freshDirectory == NSHomeDirectory(),
        "naming a session that never existed opens in the home (got \(String(describing: freshDirectory)))"
    )

    // A directory named outright — the client's recent list, whose session
    // is long gone. Same rules as an inherited one: taken when it is a
    // directory, the home when it is not, and never a failed open.
    let named = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24,
            startDirectory: "/private/tmp"
        )
    }
    var namedDirectory: String?
    let namedDeadline = Date().addingTimeInterval(5)
    while Date() < namedDeadline {
        namedDirectory = named.currentDirectory
        if namedDirectory == "/private/tmp" {
            break
        }
        usleep(50000)
    }
    check(
        namedDirectory == "/private/tmp",
        "a session opened on a named directory starts there (got \(String(describing: namedDirectory)))"
    )

    let refused = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24,
            startDirectory: "/nonexistent/ighostvt-harness"
        )
    }
    var refusedDirectory: String?
    let refusedDeadline = Date().addingTimeInterval(5)
    while Date() < refusedDeadline {
        refusedDirectory = refused.currentDirectory
        if refusedDirectory == NSHomeDirectory() {
            break
        }
        usleep(50000)
    }
    check(
        refusedDirectory == NSHomeDirectory(),
        "a named directory that is gone opens in the home (got \(String(describing: refusedDirectory)))"
    )
    check(
        harnessQueue.sync { registry.enterableDirectory("private/tmp") } == nil,
        "a relative directory is refused outright"
    )

    // A live session outranks a remembered path, since it is the same read
    // taken a moment ago rather than whenever the client last looked.
    let both = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "exec /bin/sleep 30"],
            environment: [:],
            columns: 80,
            rows: 24,
            inheritDirectoryFrom: source.id,
            startDirectory: NSHomeDirectory()
        )
    }
    var bothDirectory: String?
    let bothDeadline = Date().addingTimeInterval(5)
    while Date() < bothDeadline {
        bothDirectory = both.currentDirectory
        if bothDirectory == "/private/tmp" {
            break
        }
        usleep(50000)
    }
    check(
        bothDirectory == "/private/tmp",
        "an inherited session wins over a named directory (got \(String(describing: bothDirectory)))"
    )
    for session in [named, refused, both] {
        harnessQueue.sync { _ = try? registry.close(session.id) }
    }

    // `proc_pidinfo` keeps answering with the old path after the directory
    // is removed, so the registry's own stat check is what refuses it.
    var template = Array("/private/tmp/ighostvt-harness-cwd.XXXXXX".utf8CString)
    let removable = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }.map { String(cString: $0) }
    if let removable {
        let mover = try harnessQueue.sync {
            try registry.open(
                command: ["/bin/sh", "-c", "cd '\(removable)' && exec /bin/sleep 30"],
                environment: [:],
                columns: 80,
                rows: 24
            )
        }
        let moverDeadline = Date().addingTimeInterval(5)
        while Date() < moverDeadline, mover.currentDirectory != removable {
            usleep(50000)
        }
        check(
            harnessQueue.sync { registry.inheritableDirectory(from: mover.id) } == removable,
            "a directory that exists is offered"
        )
        check(rmdir(removable) == 0, "the harness can remove the directory under the session")
        check(mover.currentDirectory == removable, "the kernel still names the removed directory")
        check(
            harnessQueue.sync { registry.inheritableDirectory(from: mover.id) } == nil,
            "a directory that is gone is not offered"
        )
        harnessQueue.sync { _ = try? registry.close(mover.id) }
    } else {
        check(false, "a removable directory is created")
    }

    // A source that has exited offers nothing, even before it is reaped.
    let departed = try harnessQueue.sync {
        try registry.open(
            command: ["/bin/sh", "-c", "cd /private/tmp && exit 0"],
            environment: [:],
            columns: 80,
            rows: 24
        )
    }
    let departedDeadline = Date().addingTimeInterval(5)
    while Date() < departedDeadline, harnessQueue.sync(execute: { registry.session(departed.id) }) != nil {
        usleep(50000)
    }
    check(harnessQueue.sync { registry.session(departed.id) } == nil, "an exited source leaves the registry")
    check(
        harnessQueue.sync { registry.inheritableDirectory(from: departed.id) } == nil,
        "an exited source offers nothing"
    )

    for session in [source, inherited, fresh] {
        harnessQueue.sync { _ = try? registry.close(session.id) }
    }
} catch {
    check(false, "inherited-directory sessions spawn (\(error))")
}

print("foreground process name")
do {
    let session = try PTYSession(
        id: 99,
        command: ["/bin/sh", "-i"],
        environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    check(
        session.foregroundProcessName == "sh",
        "the initial foreground name is the spawned executable"
    )
    check(session.isForegroundShell, "a fresh session has its shell in the foreground")
    let namesLock = NSLock()
    var reports: [(name: String, isShell: Bool)] = []
    var directories: [String] = []
    session.start(
        onOutput: { _, _ in },
        onExit: { _, _ in },
        onForegroundChange: { session in
            namesLock.lock()
            reports.append((session.foregroundProcessName, session.isForegroundShell))
            if let directory = session.reportedDirectory, directories.last != directory {
                directories.append(directory)
            }
            namesLock.unlock()
        }
    )
    func waitForReport(_ predicate: ((name: String, isShell: Bool)) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            namesLock.lock()
            let hit = reports.contains(where: predicate)
            namesLock.unlock()
            if hit {
                return true
            }
            usleep(100_000)
        }
        return false
    }
    func waitForDirectory(_ predicate: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            namesLock.lock()
            let hit = predicate(directories)
            namesLock.unlock()
            if hit {
                return true
            }
            usleep(100_000)
        }
        return false
    }
    // The first report of all is the directory the shell started in: the
    // session reads it once the poll comes round, before anything has run.
    // Waited out and cleared here, so the foreground checks below see only
    // reports their own command caused.
    check(waitForDirectory { !$0.isEmpty }, "the session reports the directory it started in")
    namesLock.lock()
    reports.removeAll()
    namesLock.unlock()

    // An interactive sh has job control, so the sleep runs in its own
    // foreground process group; the poll must notice within a second or so.
    session.write(Data("sleep 1\n".utf8))
    let sawSleep = waitForReport { $0.name == "sleep" && !$0.isShell }
    namesLock.lock()
    var names = reports.map(\.name)
    namesLock.unlock()
    check(sawSleep, "a foreground command is reported by name, not as the shell (saw: \(names))")
    // When it ends the shell takes the terminal back, and the report says
    // so. Keyed on the flag, not the name: `proc_name` of the leader reads
    // "bash" for macOS's /bin/sh, and a nested shell would keep the name
    // anyway — the flag is what carries the change.
    let sawPrompt = waitForReport(\.isShell)
    namesLock.lock()
    names = reports.map(\.name)
    namesLock.unlock()
    check(sawPrompt, "the shell is reported back in the foreground once the command ends (saw: \(names))")
    check(session.isForegroundShell, "the session records the shell as foreground again")

    // A pipeline's group is led by its first command, which the shell reaps
    // the moment it exits while the rest runs on; `proc_name` of that leader
    // then fails. The flag has to follow the kernel's group all the same, or
    // the session reads as idle for as long as the pipeline runs.
    namesLock.lock()
    reports.removeAll()
    namesLock.unlock()
    session.write(Data("/usr/bin/true | sleep 2\n".utf8))
    let sawPipeline = waitForReport { !$0.isShell }
    namesLock.lock()
    let pipelineReports = reports
    namesLock.unlock()
    check(
        sawPipeline,
        "a pipeline whose leader is gone is still reported as running (saw: \(pipelineReports.map { "\($0.name):\($0.isShell)" }))"
    )
    check(!session.isForegroundShell, "and the session records something in front of the shell")
    check(
        pipelineReports.first(where: { !$0.isShell })?.name == names.last,
        "with the last resolved name retained rather than dropped"
    )
    check(waitForReport(\.isShell), "the shell is reported back once the pipeline ends")

    // `cd` is a builtin: it starts no process, so the foreground never
    // changes and only the directory poll can notice it. The report is what
    // the app's recent-directory list is built from.
    session.write(Data("cd /private/tmp\n".utf8))
    let moved = waitForDirectory { $0.contains("/private/tmp") }
    namesLock.lock()
    let seen = directories
    namesLock.unlock()
    check(
        moved,
        "a `cd` at the prompt is reported although no process changed (saw: \(seen))"
    )
    check(session.reportedDirectory == "/private/tmp", "and the session records where it now is")
    session.invalidate()
} catch {
    check(false, "a process-name session spawns")
}

runProxyLinkTests()

if failures.isEmpty {
    print("\nPTY harness passed")
    exit(EXIT_SUCCESS)
} else {
    print("\nPTY harness failed: \(failures.count) check(s)")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(EXIT_FAILURE)
}
