import Darwin

/// Wire contract shared by the app and `ighostvtd`.
///
/// The daemon owns every terminal session: it is the only component allowed
/// to spawn a process, and it holds the PTY, the child, and the recent output
/// buffer. The app is a view onto that state — it may attach to a session,
/// send keystrokes, and resize, but it never forks or execs anything itself.
/// Sessions therefore outlive the app: relaunching reattaches to the daemon's
/// live shells instead of starting new ones. `ighostvt-cli` is a second
/// client of the same service — one-shot commands that read a session's
/// screen or type into it without attaching, so nothing it does disturbs
/// the tab the app holds.
enum iGhostVTProtocol {
    static let version: UInt64 = 1
    static let serviceName = "wiki.qaq.ighostvt.service"
    static let clientEntitlement = "wiki.qaq.ighostvt.client"

    /// Root-owned executables permitted to open a session. Written relative to
    /// the bootstrap's root and checked against the caller's real executable
    /// path, so a roothide jbroot or a rootless `/var/jb` prefix stays intact.
    /// The CLI lives inside the app bundle so that this one rule admits both
    /// clients; the `/usr/bin` symlink the package adds is transparent here,
    /// because the kernel reports the target it executed.
    static let clientPaths = [
        "/Applications/iGhostVT.app/iGhostVT",
        "/Applications/iGhostVT.app/ighostvt-cli",
    ]

    /// The most `data` one message may carry. A hard cap on a single frame —
    /// anything larger is `invalidRequest`, never a partial read.
    static let maximumMessageDataByteCount = 1 << 20

    /// How much input a client puts in one `write` / `injectInput`. A paste
    /// is split into chunks of this size and sent one after another on the
    /// same connection, which is what makes it arrive whole and in order:
    /// XPC drains a connection's messages FIFO, the proxy forwards frames in
    /// the order it reads them, and the session appends each to its pending
    /// input in the order it is handed them. No acknowledgement is needed
    /// for that ordering, and none is waited for — a paste is not paced by a
    /// round trip per chunk.
    ///
    /// Half the message cap on purpose: the keys around `data` cost a little,
    /// and the io side's frame limit has to hold a chunk plus that.
    static let inputChunkByteCount = 512 * 1024

    /// Input `ighostvtd-io` holds for one session whose program is not
    /// reading its terminal. The kernel takes about a kilobyte ahead of the
    /// reader (`TTYHOG`) and refuses the rest with `EAGAIN`, so a paste waits
    /// here and goes in as the program reads. Generous next to any real
    /// paste, and a bound all the same: a request that would pass it is
    /// refused whole (`inputBacklog`) — never trimmed, which is what silently
    /// truncated pastes before this buffer existed.
    static let sessionPendingInputByteCount = 4 << 20

    static let maximumSessionsPerPeer = 32
    static let maximumCommandArgumentCount = 64
    static let maximumListedShellCount = 4

    /// Live sessions across every peer.
    ///
    /// The per-peer limit alone does not bound the daemon: sessions outlive
    /// the connection that opened them, so an app that opens its 32 and
    /// relaunches would leave the old ones behind and start counting from
    /// zero again. This is the ceiling that actually holds — worst case
    /// `maximumSessions × sessionReplayByteCount` of retained output, plus one
    /// shell each.
    static let maximumSessions = 64

    /// Output retained per session for replay when a client attaches. Enough
    /// for a screenful of a busy TUI plus scrollback context. Hard cap: the
    /// buffer is trimmed from the front on every append, so a session that
    /// prints forever still costs this much and no more.
    static let sessionReplayByteCount = 256 * 1024

    static let defaultColumns: UInt16 = 80
    static let defaultRows: UInt16 = 24
    static let maximumColumns: UInt16 = 2000
    static let maximumRows: UInt16 = 2000

    /// The file `ighostvtd` and `ighostvtd-io` keep their log in
    /// (`DaemonFileLog`), and where the app's log viewer reads it from — a
    /// contract between the two like the service name, which is why it is
    /// here and not in either program. Mobile's Logs on the device: writable
    /// whether the daemon runs as root or as mobile, readable by the app and
    /// over ssh without elevation. The user's Logs on the Mac, where the
    /// daemon is a per-user launch agent and the app is unsandboxed. The
    /// daemon rotates it once (`.1` appended) at half a megabyte.
    static var daemonLogPath: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
            let home = getenv("HOME").map { String(cString: $0) } ?? "/tmp"
            return home + "/Library/Logs/ighostvtd.log"
        #else
            return "/var/mobile/Library/Logs/ighostvtd.log"
        #endif
    }

    static var rotatedDaemonLogPath: String {
        daemonLogPath + ".1"
    }
}

/// Client-initiated requests. Each one gets exactly one reply.
enum iGhostVTOperation: UInt64, Sendable {
    case hello = 1
    case listSessions = 2
    case openSession = 3
    case attachSession = 4
    case detachSession = 5
    /// `data` typed (or pasted) into the attached session's PTY, in full: the
    /// session buffers whatever the kernel will not take yet and writes the
    /// rest as the program reads. Chunks sent back to back on one connection
    /// arrive in order — see `iGhostVTProtocol.inputChunkByteCount` — so the
    /// app sends them without waiting for a reply. A reply, when one is
    /// asked for, says the input was accepted, not that the program has read
    /// it.
    case write = 6
    case resize = 7
    case closeSession = 8
    case goodbye = 9
    /// Exit, if no session is held; `sessionBusy` otherwise. Sent by the app
    /// as it quits, after closing the tabs it decided to close and seeing
    /// them leave `listSessions`. Whether the exit sticks is launchd's call:
    /// the Mac's agent restarts only on a crash, the device daemon is kept
    /// alive regardless, so the app only asks on the Mac.
    case shutdown = 10
    /// The session's screen without attaching: replies with `columns`,
    /// `rows`, the foreground process, and `data` = the replay buffer, the
    /// same as an attach reply — but the peer holding the session keeps
    /// it. The CLI's `capture`; the app never sends it.
    case snapshotSession = 11
    /// `data` typed into the session's PTY by a peer that is not attached
    /// to it — `write` without the attachment gate, and buffered the same
    /// way. The CLI's `send`; the app never sends it. No new trust: any
    /// admitted peer can already `closeSession` anything it can list.
    case injectInput = 12

    /// The installed common login shells the daemon can execute. The app is
    /// sandboxed, so only the daemon can answer this against the bootstrap.
    case listShells = 13
}

/// Daemon-initiated pushes on an attached connection. These carry no reply.
enum iGhostVTEvent: UInt64, Sendable {
    case output = 100
    case sessionExit = 101
    /// What the session's terminal is doing changed; carries the foreground
    /// process's name (`processName`), whether that process is the shell the
    /// session spawned (`foregroundIsShell`) — true at the prompt, false
    /// while a command runs — and the shell's current directory
    /// (`currentDirectory`, with `displayDirectory` beside it where the two
    /// spellings differ). Also stated once in every open/attach reply, so a
    /// client knows the current state without waiting for a change.
    case processName = 102
}

enum iGhostVTReplyCode: Int64, Sendable {
    case success = 0
    case invalidRequest = 1
    case unsupportedVersion = 2
    case handshakeRequired = 3
    case sessionLimitReached = 4
    case unknownSession = 5
    case sessionBusy = 6
    case spawnFailed = 7
    case operationFailed = 8
    /// A `write` or `injectInput` refused whole: the session already holds
    /// `iGhostVTProtocol.sessionPendingInputByteCount` of input its program
    /// has not read. Nothing of the request was queued, so a client that
    /// waits for replies can send it again once the program catches up.
    case inputBacklog = 9
}

enum iGhostVTWireKey {
    static let version = "v"
    static let operation = "op"
    static let event = "ev"
    static let code = "code"
    static let sessionID = "sid"
    static let sessions = "sessions"
    static let shells = "shells"
    static let data = "data"
    static let columns = "cols"
    static let rows = "rows"
    /// On `openSession`: an argv to run verbatim, one word included. Absent
    /// or empty means a shell — the daemon's choice, or `shell`'s.
    static let command = "cmd"
    /// On `openSession`: the path of the shell to start as a login shell,
    /// the app's Settings choice. The daemon decides the argv and the
    /// environment that go with it. Distinct from a one-word `cmd`, which
    /// runs that program as itself.
    static let shell = "shell"
    static let environment = "env"
    /// On `openSession`: a live session whose shell's current directory the
    /// new one should start in. The daemon reads that directory from the
    /// kernel itself — the client never names a path.
    static let inheritDirectoryFrom = "cwdsid"
    /// On `openSession`: the directory the new session starts in, named
    /// outright. Only a path the daemon itself reported (`currentDirectory`)
    /// belongs here — it is the kernel's spelling, not a shell's — which is
    /// what lets a client offer directories whose session is long gone.
    /// `inheritDirectoryFrom` wins when both are sent, since a live session
    /// knows better than a remembered path. A path that is not a directory
    /// the session user can enter is not an error: the shell starts in the
    /// home instead, exactly as an inherited directory that went away does.
    static let startDirectory = "cwdpath"
    static let title = "title"
    static let isAttached = "attached"
    static let processName = "proc"
    /// Whether the foreground process group is the session's own shell,
    /// i.e. nothing is running in front of it.
    static let foregroundIsShell = "fgshell"
    static let exitCode = "exit"
    /// On a `listSessions` row, on event 102, and in every open/attach
    /// reply: the session shell's current directory as the kernel spells it.
    /// Absent once the child is gone or when the kernel refuses to say. This
    /// is the spelling `startDirectory` wants back.
    static let currentDirectory = "cwd"
    /// Beside `currentDirectory`: the same directory written against `@jb`
    /// instead of wherever the bootstrap really sits — a random jbroot under
    /// roothide, a prefix nobody types under rootless. Nobody would
    /// recognise `/var/containers/Bundle/Application/<uuid>/usr/src`, and
    /// `@jb/usr/src` also says which `/usr/src` it is. Absent for a path
    /// outside the bootstrap (`/var/mobile` belongs to iOS under every
    /// layout) and when there is no bootstrap at all. For display alone —
    /// `@` begins no real path, and `chdir` wants `currentDirectory`.
    static let displayDirectory = "cwddisp"
    /// Why a request failed, in words, when the reply code alone would lose
    /// the detail — the failing step and its `errno`, mainly.
    static let errorMessage = "err"
}

/// A reply code carrying the sentence the app should show.
///
/// The codes are a closed set the app can branch on; this adds the part only
/// the daemon knows — which shell it tried, which syscall refused, what the
/// system said — so a failed session can explain itself instead of showing
/// the same generic line for every cause.
struct iGhostVTFailure: Error, Equatable, Sendable {
    var code: iGhostVTReplyCode
    var message: String

    init(_ code: iGhostVTReplyCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
