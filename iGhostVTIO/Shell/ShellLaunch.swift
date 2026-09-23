import Darwin
import Foundation

/// Decides what a new session actually runs, following the same shape as
/// roothide's own terminal (<https://github.com/roothide/NewTerm>).
///
/// Two rules govern every path here, and mixing them up is the classic
/// bootstrap-path bug:
///
/// - The **executable handed to `execve`** must be what the kernel wants,
///   because neither the kernel nor this daemon is linked against libvroot.
///   Resolve it with `RuntimeEnvironment.resolve`.
/// - Every path **inside the environment** must stay in the bootstrap's own
///   vocabulary, because the programs that read it — the bootstrap's `login`,
///   `zsh`, and the coreutils they exec — read it their way: unprefixed under
///   roothide, where vroot resolves `/` against the jbroot on their behalf,
///   and `/var/jb`-prefixed under rootless, where that prefix is compiled in.
///   `RuntimeEnvironment.bootstrapPath` and `.systemPath` spell both; never
///   hardcode either form.
enum ShellLaunch {
    struct Plan {
        var command: [String]
        var environment: [String: String]
        /// Who the shell should run as; the daemon drops privileges itself in
        /// the forked child. `nil` when there is nothing to drop (harness).
        var credentials: Credentials?
        /// Where the session starts, as `chdir` wants it. `nil` leaves the
        /// daemon's own directory — launchd's `/`, which is what every
        /// session used to get and what a terminal should never open on.
        var workingDirectory: String?

        init(
            command: [String],
            environment: [String: String],
            credentials: Credentials? = nil,
            workingDirectory: String? = nil
        ) {
            self.command = command
            self.environment = environment
            self.credentials = credentials
            self.workingDirectory = workingDirectory
        }
    }

    /// The identity a session drops to before `execve`.
    struct Credentials: Equatable {
        var uid: uid_t
        var gid: gid_t
    }

    /// Shells to try when the bootstrap's passwd database has nothing usable.
    /// Written relative to the bootstrap's own root; `firstExecutable` adds
    /// whatever prefix the active bootstrap needs.
    private static let fallbackShells = [
        "/bin/zsh",
        "/bin/bash",
        "/bin/sh",
    ]

    /// Stable paths offered by Settings. Only executable entries are sent to
    /// the sandboxed app; custom paths remain available for every other shell.
    static var availableShellPaths: [String] {
        [
            "/usr/bin/fish",
            "/bin/zsh",
            "/bin/bash",
            "/bin/sh",
        ].filter { locate($0) != nil }
    }

    /// Where the bootstrap keeps its tools, and where iOS keeps its own.
    private static let bootstrapBinaryDirectories = [
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    ]

    private static let systemBinaryDirectories = [
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    ]

    /// The `PATH` every session gets — the daemon establishes it because it
    /// spawns the shell itself (see `plan` for why `login` is off the table).
    ///
    /// The bootstrap's tools come first, iOS's own after: without the second
    /// half a shell reaches everything the bootstrap installed and nothing the
    /// system ships. How each half is spelled is the runtime environment's business —
    /// roothide bridges the untouched filesystem in at `/rootfs`, rootless
    /// prefixes its own half instead — so both go through `RuntimeEnvironment`, and
    /// the duplicates the two halves collapse into without a prefix are
    /// dropped.
    private static var fallbackPath: String {
        var directories: [String] = []
        let candidates = bootstrapBinaryDirectories.map(RuntimeEnvironment.bootstrapPath)
            + systemBinaryDirectories.map(RuntimeEnvironment.systemPath)
        for directory in candidates where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// Locale names to try, best first.
    ///
    /// The C library resolves a locale by opening
    /// `/usr/share/locale/<name>/<category>`, and it looks at the **real**
    /// root, not the jbroot — libc is not vroot-linked. iOS ships exactly one
    /// entry there, the bare `UTF-8`, and that directory holds `LC_CTYPE` and
    /// nothing else. `en_US.UTF-8` exists only inside the bootstrap, where
    /// libc will never look. (macOS, where the harness runs, has both, fully
    /// populated.)
    ///
    /// Naming a locale that cannot be loaded is worse than naming none:
    /// `setlocale` fails, every locale-aware program silently falls back to C,
    /// and multibyte text is then counted and drawn one byte at a time. The
    /// symptom is CJK turning into mojibake *as you type it* while the same
    /// bytes come back correct from a program's stdout — the line editor is
    /// redrawing byte by byte, the program's own output is one clean write.
    private static let localeCandidates = [
        "en_US.UTF-8",
        "UTF-8",
    ]

    /// The first locale whose `LC_CTYPE` the system can actually load.
    ///
    /// Character handling is exported through **`LC_CTYPE` alone** — never
    /// `LANG`, and never `LC_ALL`.
    ///
    /// Both of those set *every* category at once, and on iOS the only locale
    /// present has just the one category, so both fail outright and drop the
    /// whole process back to C. Measured on device, with the same shell and
    /// the same string:
    ///
    ///     LC_CTYPE=UTF-8   ${#你好} → 2, silent
    ///     LC_ALL=UTF-8     ${#你好} → 2, but warns on every shell start
    ///     LANG=UTF-8       ${#你好} → 6
    ///
    /// Leaving `LANG` unset costs nothing here: messages and collation have no
    /// data on iOS either way, and the shell's rc files can still set it.
    static var preferredLocale: String {
        localeCandidates.first {
            FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)/LC_CTYPE")
        } ?? "UTF-8"
    }

    /// The name every iOS terminal gives its sessions, and the uid the rest of
    /// the user's filesystem is owned by.
    private static let preferredUserName = "mobile"
    private static let preferredUserID: uid_t = 501

    /// Who a session runs as: **mobile**, not the daemon's own root.
    ///
    /// `ighostvtd` is a root LaunchDaemon, so a session inherits root unless it
    /// is told otherwise — but a root shell is the wrong default here. Every
    /// other terminal on the device lands the user at `mobile`, `$HOME` and
    /// the caches a shell touches belong to 501, and files created as root in
    /// `/var/mobile` break the apps that own them afterwards. Escalation is a
    /// `sudo` away, which is the direction that can be undone.
    ///
    /// Off-device (the harness) there is no `mobile`, so this degrades to the
    /// daemon's own user and no privileges are dropped.
    private static var sessionUser: PasswdEntry? {
        PasswdEntry.forUser(name: preferredUserName)
            ?? PasswdEntry.forUser(id: preferredUserID)
            ?? PasswdEntry.forCurrentUser()
    }

    /// The identity to drop to, or `nil` when the session already runs as the
    /// right user — only root can change uid, and dropping to ourselves is a
    /// no-op worth skipping.
    static func credentials(for user: PasswdEntry?) -> Credentials? {
        guard let user, getuid() == 0, user.uid != 0 else { return nil }
        return Credentials(uid: user.uid, gid: user.gid)
    }

    /// What every session's program finds in its environment, shell or
    /// not: the terminal's identity and the user's, and a `PATH` — the
    /// daemon's own is launchd's, and the session runs as someone else.
    private static func baseEnvironment(for user: PasswdEntry?) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "iGhostVT",
            "LC_TERMINAL": "iGhostVT",
            "LC_CTYPE": preferredLocale,
        ]
        environment.merge(userEnvironment(for: user)) { current, _ in current }
        environment["PATH"] = fallbackPath
        return environment
    }

    static func plan(requestedShell: String?) -> Plan? {
        let user = sessionUser

        // An explicit choice from the app's settings wins.
        if let requestedShell, !requestedShell.isEmpty {
            guard requestedShell.hasPrefix("/"),
                  let shell = locate(requestedShell)
            else { return nil }
            return directShellPlan(shell: shell, user: user)
        }

        // Every session is spawned directly — never through the bootstrap's
        // `login`, tempting as its utmp entry and login class are. Procursus's
        // `/etc/pam.d/login` runs `pam_launchd.so`, which moves the session
        // into a per-user bootstrap namespace; on jailbroken iOS that
        // namespace cannot reach `com.apple.dnssd.service`, and iOS has no
        // `/etc/resolv.conf` to fall back on, so every `login`-spawned process
        // keeps TCP but loses DNS entirely ("Could not resolve host" from a
        // shell whose `curl --dns-servers 8.8.8.8` works fine). Procursus
        // ships `pam.d/sshd` with that very module commented out — which is
        // why ssh sessions resolve and `login` sessions do not. Spawning the
        // shell ourselves involves no PAM, so the session keeps the daemon's
        // namespace and its DNS; it also lets bash carry `--posix` for shell
        // integration, which `login` (choosing argv itself) never could.
        //
        // Run the passwd shell, and supply both the environment and the
        // identity that `login` would have established.
        var shell = firstExecutable(fallbackShells)
        if let passwdShell = user?.shell, RuntimeEnvironment.isExecutable(passwdShell) {
            shell = passwdShell
        }
        guard let shell else { return nil }

        return directShellPlan(shell: shell, user: user)
    }

    /// The daemon spawns the shell itself instead of handing off to `login`,
    /// so it supplies both the environment and the identity `login` would have
    /// established.
    private static func directShellPlan(shell: String, user: PasswdEntry?) -> Plan {
        var environment = baseEnvironment(for: user)
        environment["SHELL"] = shell
        // After `HOME`: bash's integration moves the history file relative to
        // it, and reads nothing this daemon sets afterwards.
        let integrationArguments = ShellIntegration.apply(shell: shell, to: &environment)
        return Plan(
            command: [RuntimeEnvironment.resolve(shell)] + integrationArguments + ["-il"],
            environment: environment,
            credentials: credentials(for: user),
            workingDirectory: workingDirectory(for: user)
        )
    }

    /// The session user's home, in the spelling the filesystem actually
    /// has. The passwd entry speaks the bootstrap's vocabulary; under
    /// roothide that resolves inside the jbroot or is the real
    /// `/var/mobile`, so the first spelling that is a directory wins.
    static func workingDirectory(for user: PasswdEntry?) -> String? {
        guard let user, !user.home.isEmpty else { return nil }
        return [RuntimeEnvironment.resolve(user.home), user.home].first(where: isDirectory)
    }

    /// Where a session with no directory of its own starts, for the one
    /// caller that needs to *recognise* it rather than use it: the
    /// directory reporter, which shows it as `~`.
    ///
    /// Only the daemon can answer this. Under roothide the home is
    /// `<jbroot>/var/mobile`, not `/var/mobile` — the passwd entry says
    /// the latter and `resolve` finds the former — so an app matching
    /// `/var/mobile` against the path would call the jbroot's home
    /// something else and iOS's own `/var/mobile` the home. Both of those
    /// are wrong, and it made the wrong one every time.
    ///
    /// Resolved once: the passwd file is not going to change under a
    /// running daemon, and this is read on every directory report.
    static let sessionHomeDirectory: String? = workingDirectory(for: sessionUser)

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A caller-supplied argv is still a session: it runs as `mobile`, from
    /// mobile's home, in the terminal's environment — `TERM` is what a curses
    /// program needs to start at all. Only the shell integration is left
    /// off: it shapes argv, and this argv is the caller's.
    static func verbatimPlan(command: [String]) -> Plan {
        let user = sessionUser
        var environment = baseEnvironment(for: user)
        if let shell = user?.shell, !shell.isEmpty {
            environment["SHELL"] = shell
        }
        return Plan(
            command: command,
            environment: environment,
            credentials: credentials(for: user),
            workingDirectory: workingDirectory(for: user)
        )
    }

    /// The identity half of the environment `login` would have exported. It
    /// comes out of the bootstrap's passwd database already spelled the way
    /// the bootstrap's own programs want it, and is passed through untouched.
    private static func userEnvironment(for user: PasswdEntry?) -> [String: String] {
        guard let user else { return [:] }
        return [
            "HOME": user.home,
            "USER": user.name,
            "LOGNAME": user.name,
        ]
    }

    /// Validates a caller-supplied command: absolute, present, executable.
    static func validate(_ command: [String]) -> [String]? {
        guard command.count <= iGhostVTProtocol.maximumCommandArgumentCount,
              let executable = command.first,
              executable.hasPrefix("/"),
              RuntimeEnvironment.isExecutable(executable)
        else { return nil }
        var resolved = command
        resolved[0] = RuntimeEnvironment.resolve(executable)
        return resolved
    }

    /// The first of a set of paths inside the bootstrap's root that is there
    /// and executable, in the bootstrap's own spelling.
    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.map(RuntimeEnvironment.bootstrapPath).first(where: RuntimeEnvironment.isExecutable)
    }

    /// A shell the user named in the app's settings, in whichever spelling
    /// they used. Under rootless `/var/jb/bin/zsh` and the bare `/bin/zsh` a
    /// user carries over from another environment name the same file, and there
    /// is no reason to reject one of them; under roothide and without a prefix
    /// the two spellings are identical and this is a single check.
    private static func locate(_ shell: String) -> String? {
        [shell, RuntimeEnvironment.bootstrapPath(shell)].first(where: RuntimeEnvironment.isExecutable)
    }
}

/// A line of the bootstrap's `/etc/passwd`.
///
/// Read from the bootstrap's own root rather than through `getpwuid`, because
/// libc answers from the *system's* database. The bootstrap keeps its own, and
/// its shell and home entries are the ones a session wants — already in the
/// spelling the bootstrap's programs use.
/// (roothide's terminal reaches the same file through libvroot's
/// `ie_getpwuid_r`; this daemon is not vroot-linked, so it reads it directly.)
struct PasswdEntry {
    var name: String
    var uid: uid_t
    var gid: gid_t
    var home: String
    var shell: String

    static func forCurrentUser() -> PasswdEntry? {
        forUser(id: getuid()) ?? systemEntry(id: getuid())
    }

    static func forUser(id: uid_t) -> PasswdEntry? {
        first { $0.uid == id }
    }

    static func forUser(name: String) -> PasswdEntry? {
        first { $0.name == name }
    }

    private static func first(where matches: (PasswdEntry) -> Bool) -> PasswdEntry? {
        guard let contents = try? String(
            contentsOfFile: RuntimeEnvironment.resolve(RuntimeEnvironment.bootstrapPath("/etc/passwd")),
            encoding: .utf8
        ) else { return nil }

        for line in contents.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7,
                  let uid = uid_t(fields[2]),
                  let gid = gid_t(fields[3])
            else { continue }
            let entry = PasswdEntry(
                name: String(fields[0]),
                uid: uid,
                gid: gid,
                home: String(fields[5]),
                shell: String(fields[6])
            )
            if matches(entry) {
                return entry
            }
        }
        return nil
    }

    /// Fallback for a host with no bootstrap passwd — the harness, mainly.
    private static func systemEntry(id: uid_t) -> PasswdEntry? {
        guard let pwd = getpwuid(id) else { return nil }
        return PasswdEntry(
            name: String(cString: pwd.pointee.pw_name),
            uid: pwd.pointee.pw_uid,
            gid: pwd.pointee.pw_gid,
            home: String(cString: pwd.pointee.pw_dir),
            shell: String(cString: pwd.pointee.pw_shell)
        )
    }
}
