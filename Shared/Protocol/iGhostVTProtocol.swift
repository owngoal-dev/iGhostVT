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

    /// `uploadFile`: the most one file may be, the most begun and not yet
    /// finished at once, and how much one part carries — small enough that
    /// a part lost to a weak link costs little to send again.
    static let maximumUploadByteCount: UInt64 = 4 << 30
    static let maximumPendingUploadCount = 16
    static let uploadChunkByteCount = 256 * 1024
    static let maximumCommandArgumentCount = 64
    static let maximumListedShellCount = 4

    /// Live sessions across every peer.
    ///
    /// The per-peer limit alone does not bound the daemon: sessions outlive
    /// the connection that opened them, so an app that opens its 32 and
    /// relaunches would leave the old ones behind and start counting from
    /// zero again. This is the ceiling that actually holds — worst case
    /// `maximumSessions × 2 × sessionReplayByteCount` of retained output, plus one
    /// shell each.
    static let maximumSessions = 64

    /// Output retained per session for replay when a client attaches. Enough
    /// for a screenful of a busy TUI plus scrollback context. Hard cap: the
    /// buffer is trimmed from the front in batches, so a session that prints
    /// forever costs at most twice this much.
    static let sessionReplayByteCount = 256 * 1024

    /// What one session's attributes (`setSessionAttributes`) may hold: at
    /// most this many keys, and this many bytes of UTF-8 across every key
    /// and value together. A request past either is refused whole. Room for
    /// a handful of per-tab choices, and a bound the io side can promise for
    /// `maximumSessions` of them.
    static let maximumSessionAttributeCount = 16
    static let maximumSessionAttributeByteCount = 4096

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
    /// `watchSessions` asks for the session events every watcher gets
    /// (`sessionOpened`, `sessionReleased`) for as long as the connection
    /// lasts: the app's one connection that keeps its windows in step with
    /// what other devices do.
    case hello = 1
    case listSessions = 2
    /// `holder` names the device the session is opened for (the remote
    /// helper sets it), and every watcher hears of the session.
    case openSession = 3
    /// Exclusive: a session held by another peer is `sessionBusy`, with the
    /// holder's name in `holder` when it has one. `takeover` takes it
    /// instead — the peer that held it is sent `sessionTaken` and detached.
    /// `holder` as on `openSession`.
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

    /// Replaces the session's attributes with `attributes` — a string-to-
    /// string dictionary the daemon stores and hands back but never reads:
    /// in every attach and snapshot reply, on every `listSessions` row, and
    /// (empty) in the open reply. What a client sets on a tab and wants to
    /// find again after a relaunch lives here, because the session is the
    /// one thing that survives the app. Replace, not merge: a client sends
    /// everything it keeps, an empty dictionary clears them, and the key
    /// is required. Over `maximumSessionAttributeCount` keys or
    /// `maximumSessionAttributeByteCount` bytes, or a value that is not a
    /// string, is `invalidRequest` and changes nothing. Any admitted peer
    /// may set them on any live session, attached or not — the trust of
    /// `closeSession` — and they die with the session. A daemon older than
    /// this operation answers `invalidRequest`, which a client takes to
    /// mean "keep them in memory only".
    case setSessionAttributes = 14

    /// Copies a file onto this device for a shell here to read — a drop on
    /// a tab whose shell runs on another device. Three shapes:
    /// - `fileName` and `fileSize`: begins one; answered with `upload` (its
    ///   id) and `path`, where the file will be. A client may name the id
    ///   itself in `upload`, so a begin sent again after its answer was lost
    ///   answers again rather than making a second file.
    /// - `upload`, `offset`, `data`: the next part, at most
    ///   `uploadChunkByteCount`. A part may overlap what the host holds —
    ///   an old link's parts can land after a new link asked — and only its
    ///   new end is written; one that would leave a hole is
    ///   `invalidRequest` with nothing written.
    /// - `upload` alone: how much is here, in `offset` — what a client asks
    ///   after its link dropped, before it carries on. `cancel` as well:
    ///   give it up and remove the partial file.
    /// Every reply about an upload states `offset`. An upload outlives the
    /// connection that began it (a weak network drops links mid-file) and is
    /// given up only after a quarter of an hour without a word; one the host
    /// does not know is `unknownSession`. Any admitted peer may upload — it
    /// could already open a shell that writes anything it likes. A daemon
    /// older than this answers `invalidRequest` to the first shape.
    case uploadFile = 15

    // Remote access: the local management of `ighostvtd-remote`. Any
    // admitted local peer may send them except the remote helper itself;
    // the proxy answers `setRemoteAccess` and hands the rest to the helper.
    // None of them is reachable from the network.

    /// The switch, the helper's state, the pairing window, the paired
    /// devices. With the helper not running, the proxy answers with
    /// `enabled` and `remoteState` alone.
    case remoteStatus = 20
    /// `enabled`: turns remote access on or off. The proxy keeps the switch
    /// as a file only it can write (`RemoteSupervisor.flagPath`) — that
    /// file is what a launch reads — and starts or stops the helper.
    case setRemoteAccess = 21
    /// Opens the pairing window and answers with its `pairingCode` and
    /// `pairingExpiresAt`. Opening it again issues a new code.
    case beginPairing = 22
    case endPairing = 23
    /// `deviceID`: forgets a paired device; its key stops working at once.
    case revokeRemoteDevice = 24
    /// `hostName`: what this device is called on the others' screens —
    /// advertised, and named in their lists. Empty goes back to the name
    /// the owner gave the device in Settings.
    case setHostName = 25
    /// `relay`: the relay configuration (a `.vtrpsc` file's bytes) this
    /// host registers with, empty to stop using one. The app keeps the
    /// file and is the one truth about it: `remoteStatus` reports the
    /// helper's `relayFingerprint`, and the app sends this again whenever
    /// that differs from its own. The payload holds a private key — nothing
    /// that handles it may log it.
    case setRelayConfiguration = 26

    // Remote access: spoken by the app to `ighostvtd-remote` over the
    // pairing link only (see `RemoteAccess`), never to the daemon.

    /// `deviceID`, `deviceName`, `share` (the prover's SPAKE2+ share).
    /// Answered with `hostID`, `hostName`, `share`, `confirmation`.
    case pairStart = 30
    /// `confirmation` (the prover's). Answered with success, or with
    /// `invalidRequest` for a wrong code.
    case pairFinish = 31
    /// Answered at once by `ighostvtd-remote` itself, never forwarded: an
    /// end-to-end heartbeat for a link through a relay. TCP keepalive only
    /// proves each leg to the next box, and a proxy on the way answers it
    /// for a peer that is long gone; this crosses the whole path. The app
    /// sends it on a quiet relayed link and gives the link up when nothing
    /// comes back; the helper drops a relayed device that has sent nothing
    /// for `RemoteAccess.deviceSilenceLimit`.
    case ping = 32
}

/// The attribute keys and values the app keeps on a session
/// (`iGhostVTOperation.setSessionAttributes`). The daemon reads none of
/// them; they are written down here so the CLI can show what the app set.
enum iGhostVTSessionAttribute {
    /// The tab's lock: `interaction` or `keyboard`; absent when unlocked.
    static let lock = "lock"
    static let interactionLock = "interaction"
    static let keyboardLock = "keyboard"
    /// The title the tab shows (`TerminalTab.displayTitle`'s reported
    /// part), so another device's new-tab menu names the terminal the way
    /// this one does; absent while the session has reported none.
    static let title = "title"
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
    /// To the peer that held the session: another took it (`takeover`).
    /// `holder` names who, when it was a device; absent for this device's
    /// own app. The peer is detached already.
    case sessionTaken = 103
    /// To watchers: a session is now held for a device (`holder`) — opened
    /// for it, or attached by it, from whoever had it — so a window shows
    /// it as a tab and names the device.
    case sessionOpened = 104
    /// To watchers: the device holding a session let go of it — detached,
    /// or its connection went — and the session lives on, free.
    case sessionReleased = 105
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
    /// On `write` and `injectInput`: one id on every chunk of an input sent
    /// as several messages (a paste). Once the session refuses one chunk as
    /// `inputBacklog`, it refuses every later chunk with the same id, so a
    /// paste arrives whole or as a prefix — never with a hole where a
    /// refused chunk was. Absent or 0 for input that is one message.
    static let paste = "paste"
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
    /// Beside `currentDirectory`: the same directory as a person should
    /// read it. The session user's home is `~`, anything else inside the
    /// bootstrap is written against `@jb` — nobody would recognise
    /// `/var/containers/Bundle/Application/<uuid>/usr/src`, and
    /// `@jb/usr/src` also says which `/usr/src` it is. Absent for a path
    /// that is already its own best spelling.
    ///
    /// Only the daemon can work either of these out. The home is *not*
    /// `/var/mobile` under roothide — the passwd entry says that and it
    /// resolves inside the jbroot — so a client matching that path names
    /// the wrong directory in both directions. For display alone: `~` and
    /// `@` begin no real path, and `chdir` wants `currentDirectory`.
    static let displayDirectory = "cwddisp"
    /// Why a request failed, in words, when the reply code alone would lose
    /// the detail — the failing step and its `errno`, mainly.
    static let errorMessage = "err"
    /// The session's attributes (`setSessionAttributes`): a dictionary of
    /// strings, on that request, in open/attach/snapshot replies, and on
    /// every `listSessions` row.
    static let attributes = "attrs"
    /// The device a session is held by or opened for: on `openSession` and
    /// `attachSession` (set by the remote helper), on a `sessionBusy`
    /// attach reply, on `listSessions` rows, and on the session events.
    static let holder = "holder"
    /// On `attachSession`: take the session from whoever holds it.
    static let takeover = "takeover"
    /// On `hello`: send this connection the watcher events.
    static let watchSessions = "watch"

    /// `uploadFile`.
    static let fileName = "fname"
    static let fileSize = "fsize"
    static let upload = "upid"
    static let offset = "off"
    static let path = "path"
    static let cancel = "cancel"

    /// Remote access.
    static let enabled = "enabled"
    /// `off`, `starting`, `listening` or `failed` (`RemoteAccessState`).
    static let remoteState = "rstate"
    static let hostID = "hostid"
    static let hostName = "hostname"
    static let port = "port"
    static let pairingCode = "paircode"
    /// Seconds since 1970, as an int64.
    static let pairingExpiresAt = "pairexp"
    /// Failed attempts in the current window: an array of dictionaries
    /// with `address` and `time`.
    static let pairingFailures = "pairfail"
    static let address = "addr"
    static let time = "time"
    /// Paired devices: an array of dictionaries with `deviceID`,
    /// `deviceName`, `time` (paired at) and `lastSeen`.
    static let devices = "devices"
    static let deviceID = "devid"
    static let deviceName = "devname"
    static let lastSeen = "seen"
    static let share = "share"
    static let confirmation = "confirm"
    /// On `remoteStatus`: paired devices connected right now.
    static let connectedCount = "connected"
    /// On a remote `hello` and `pairStart`, on the host's refusal of either
    /// (`unsupportedVersion`), and on `remoteStatus`: the iGhostVT version
    /// (`CFBundleShortVersionString`) the sender runs. Two devices connect
    /// only when theirs are equal.
    static let appVersion = "appver"
    /// `setRelayConfiguration`: the `.vtrpsc` bytes.
    static let relay = "relay"
    /// On `remoteStatus`: the relay the helper uses (`RelayConfiguration.fingerprint`),
    /// empty for none. Absent when the helper is not running.
    static let relayFingerprint = "relayfp"
    /// On `remoteStatus`: `RelayState`, and the relay's name and what went
    /// wrong with it, if anything.
    static let relayState = "relaystate"
    static let relayName = "relayname"
    static let relayMessage = "relaymsg"
    /// On `beginPairing`: the window also accepts a pairing that comes in
    /// through the relay. Off unless asked for.
    static let relayPairing = "relaypair"
}

/// The remote helper's state, as `remoteStatus` reports it.
enum RemoteAccessState: String, Sendable {
    case off
    case starting
    case listening
    case failed
}

/// The host's registration with its relay, as `remoteStatus` reports it.
enum RelayState: String, Sendable {
    /// No relay configured.
    case off
    case connecting
    case registered
    /// Could not reach or register; tried again with a backoff.
    case failed
    /// Another machine registered this host id with this host's key — a
    /// copied identity. Not retried until the configuration changes.
    case conflict
    /// The relay speaks another protocol version. Not retried.
    case versionMismatch
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
