import Combine
import Foundation
import GhosttyTerminal
import os

/// Glues a `TerminalTransport` to libghostty's host-managed terminal session.
///
/// Bytes the terminal produces (keystrokes) go out through the transport;
/// bytes the transport receives are fed back into the terminal. Connection
/// status is echoed into the terminal itself as dim status lines, so the
/// surface doubles as the connection log.
@MainActor
final class TerminalSessionStore: ObservableObject {
    // The whole session pipeline logs to `AppLog` (`.session`) because a
    // black surface has no other way to say where it stopped: no viewport
    // line means the surface never attached, no connect line means the
    // transport was never asked.

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        /// The session is open on another device (`holder`), or in
        /// another window of this app (nil); the tab offers to take it.
        case elsewhere(String?)
    }

    /// The device using the session, while one is (`Status.elsewhere`).
    var heldBy: String? {
        if case let .elsewhere(holder) = status {
            return holder
        }
        return nil
    }

    /// Whether another peer has the session (`Status.elsewhere`).
    var isHeldElsewhere: Bool {
        if case .elsewhere = status {
            return true
        }
        return false
    }

    @Published private(set) var status: Status = .idle {
        didSet {
            if status == .connected, oldValue != .connected {
                // A fresh attach since the app came forward: the tab has
                // the session, so a later loss is someone else's choice.
                takeoverArmed = false
            }
            claimIfArmed()
        }
    }

    /// One automatic Use Here, armed each time the app comes back to the
    /// foreground (`TabManager.armForegroundTakeover`). The first time the
    /// tab is in front afterwards, a session another device holds is taken
    /// back without asking — coming back to the app is the person saying
    /// they are here now. Spent by that takeover, by a fresh attach, or by
    /// `takeoverGrace` in front still connected; after that, a device that
    /// takes the session again is met with the card, as before. Two devices
    /// cannot trade a session back and forth on their own: each takes it at
    /// most once per return to the foreground, and only a person brings an
    /// app forward.
    private var takeoverArmed = false
    private var takeoverGeneration = 0
    private static let takeoverGrace: UInt64 = 5_000_000_000

    /// The tab is the one its window shows (`TabManager`).
    var isFrontTab = false {
        didSet {
            if isFrontTab != oldValue { claimIfArmed() }
        }
    }

    func armForegroundTakeover() {
        takeoverArmed = true
        takeoverGeneration &+= 1
        claimIfArmed()
    }

    private func claimIfArmed() {
        guard takeoverArmed, isFrontTab else { return }
        switch status {
        case let .elsewhere(holder?):
            takeoverArmed = false
            AppLog.info(.session, "back in the foreground: taking the session from \(holder)")
            // Not from inside `status`'s own observer: the takeover sets it.
            Task { @MainActor [weak self] in
                guard let self, case .elsewhere = status else { return }
                takeOver()
            }
        case .elsewhere(nil):
            // Another window of this app holds it; windows never fight.
            takeoverArmed = false
        case .connected:
            // A link that looked fine as the app came forward may have
            // died while it was suspended — it is found out within seconds
            // and the reconnect then meets the holder. Seen connected that
            // long, the tab has the session.
            let generation = takeoverGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.takeoverGrace)
                guard let self, takeoverGeneration == generation, isFrontTab, status == .connected else { return }
                takeoverArmed = false
            }
        case .idle, .connecting, .failed:
            break
        }
    }

    /// Whether the session is sitting on a failure a retry could clear. Read
    /// by `TabManager.retryFailedTabs()` when the reason for the failure was
    /// external — on the Mac, a daemon that had not been approved yet.
    var hasFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    /// Exit status of the session's process once it has ended, nil while it
    /// lives (or before it ever ran). Branches the failure card: an exited
    /// shell is an outcome to acknowledge, a lost daemon is an error to
    /// retry. Set through the tab's transport wiring — the transport's exit
    /// event is the only trustworthy signal, reason strings are for humans.
    @Published private(set) var processExitStatus: Int32?

    /// Title guessed from the last command the user typed, used only while
    /// the shell reports none of its own. Empty until a command is accepted.
    ///
    /// See ``CommandTitleTracker``: the tracker offers a line, this decides
    /// whether it made it to the screen. An unechoed line — a password, a
    /// key a full-screen program swallowed — never becomes a title.
    @Published private(set) var inferredTitle: String = ""

    /// Name of the process in the foreground on the session's terminal, as
    /// the daemon reports it ("zsh", "vim", "grok"). Empty until the first
    /// report — a transport that cannot know never sends one.
    @Published private(set) var processName: String = ""

    /// Whether the foreground process is the session's own shell — nothing
    /// running in front of it, as the daemon reports alongside
    /// `processName`. False until the first report, so an unknown state
    /// reads as "something may be running". Reset on every connect: a
    /// reattach restates it, and the value from before a detach is stale.
    @Published private(set) var isShellInForeground = false

    /// Where the session's shell is, as the daemon last reported it — the
    /// kernel's reading, not the shell's own OSC 7, so it is a path a new
    /// session can be opened in. `nil` until the first report, and again on
    /// every connect: a reattach restates it, and the value from before a
    /// detach names wherever the shell was left, which may have moved.
    @Published private(set) var currentDirectory: TerminalDirectory?

    /// Whether a connected session has been silent since it was opened
    /// for longer than a shell takes to print its prompt. A connected
    /// terminal with nothing on it is indistinguishable from a broken one
    /// — the first zsh after a userspace reboot takes ~30 s to say its
    /// first word (oh-my-zsh on cold caches under a 500 load average),
    /// and the pane sat empty with no sign anything was coming. True only
    /// after `firstOutputGrace`, so a shell that prints within the second
    /// never flashes the pill; cleared by the first byte the session
    /// writes (a replay counts) and by any state change.
    @Published private(set) var isAwaitingFirstOutput = false

    /// Whether a paste was just cut short because the program is not
    /// reading its input (`TerminalTransportEvent.inputRefused`). Up for a
    /// few seconds: the user pasted and saw only part of it arrive, and
    /// nothing on the terminal says why.
    @Published private(set) var isPasteTruncated = false
    private var pasteNoticeGeneration: UInt64 = 0
    private static let pasteNoticeDuration: UInt64 = 4_000_000_000
    private var hasReceivedOutput = false
    private var firstOutputGeneration: UInt64 = 0
    private static let firstOutputGrace: UInt64 = 1_000_000_000

    /// The ZMODEM transfer in flight, when `rz`/`sz` detection is on and a
    /// handshake was seen. Drives the progress pill; nil the rest of the time.
    @Published private(set) var zmodemTransfer: ZmodemTransferInfo?

    /// Whether the shell is verifiably sitting at its prompt. Only a
    /// connected session can vouch for that — a detached session's last
    /// report is stale, and an unknown state reads as "something may be
    /// running". This is the one spelling of that rule: the close
    /// confirmation (`TerminalTab.hasRunningProgram`) and the resize
    /// throttle both read it, so a change here changes both.
    var isIdleAtPrompt: Bool {
        Self.isIdleAtPrompt(status: status, isShellInForeground: isShellInForeground)
    }

    /// The rule itself, for judging values still in flight: a `@Published`
    /// publisher emits *before* the property is written, so a Combine map
    /// must apply the rule to the emitted pair, not to the stored one.
    static func isIdleAtPrompt(status: Status, isShellInForeground: Bool) -> Bool {
        status == .connected && isShellInForeground
    }

    let session: InMemoryTerminalSession
    private let relay = TransportRelay()
    private let titleTracker = CommandTitleTracker()
    /// The ZMODEM endpoint for this connection, created in `connect()` when
    /// the setting is on. Interposes on received output; nil means the feature
    /// is off and the output path is the plain one.
    private var zmodemEngine: ZmodemEngine?
    private var hasAutoConnected = false
    private var isSceneActive = false
    private let makeTransport: () -> TerminalTransport
    var recordsRecentDirectories = true
    /// The paired device the session runs on (remote access): its
    /// directories are remembered under that device, never as this one's.
    var recentDirectoryHostID: String?
    /// A session on another device: its link drops with the network, not
    /// only with a daemon restart, so it is tried for a minute of network,
    /// backing off (`patientReconnectDelay`), before the tab says it failed
    /// — and again at once whenever the app comes forward or the network
    /// comes back (`reconnectNow`). Time with no network at all does not
    /// count against the minute: there was nothing to try.
    var reconnectsPatiently = false
    private var reconnectStartedAt: Date?
    private static let patientReconnectWindow: TimeInterval = 60

    /// Reconnect-after-interruption state. The daemon may still hold the
    /// session when the link drops (its KeepAlive restart, mostly), so a few
    /// paced attempts reattach and resume before anything is declared failed.
    /// The generation invalidates a scheduled attempt when the user connects
    /// or disconnects by hand in the meantime.
    private var reconnectAttempt = 0
    private var reconnectGeneration: UInt64 = 0
    private static let reconnectAttemptLimit = 5
    private static let reconnectDelay: UInt64 = 1_000_000_000

    /// What the endpoint keeps on the session, each time the session is
    /// opened or reattached (`TerminalTransportEvent.sessionAttributes`).
    /// Installed by the tab, which owns what they mean.
    var onSessionAttributes: ((_ attributes: [String: String], _ isResumed: Bool) -> Void)?

    /// Hands `attributes` to the connected transport. False when there is
    /// no connection to carry them — the caller keeps them and tries again
    /// on the next `onSessionAttributes`.
    func setSessionAttributes(_ attributes: [String: String]) -> Bool {
        guard status == .connected, let transport = relay.transport else { return false }
        transport.setSessionAttributes(attributes)
        return true
    }

    /// The transport of the current connection, for callers that need
    /// implementation-specific capability (daemon session control).
    var activeTransport: TerminalTransport? {
        relay.transport
    }

    /// Where this session's bytes go, for titles and the sidebar subtitle.
    var endpointDescription: String {
        relay.transport?.endpointDescription ?? String(localized: "Terminal")
    }

    /// The transport factory is the backend seam: tabs hand in the daemon
    /// transport today, and an SSH-backed session swaps the factory without
    /// touching the store, the tabs, or the interface.
    init(makeTransport: @escaping () -> TerminalTransport) {
        self.makeTransport = makeTransport

        let relay = relay
        let titleTracker = titleTracker
        session = InMemoryTerminalSession(
            write: { data in
                relay.send(data)
                titleTracker.consume(data)
            },
            resize: { viewport in
                // Logged here, on the reporting thread, rather than from a
                // main-actor hop: only the grid is consumed, and the relay
                // needs no help from the main actor to forward it.
                AppLog.info(.session, "surface reported viewport \(viewport.columns)x\(viewport.rows)")
                relay.updateViewport(
                    columns: Int(viewport.columns),
                    rows: Int(viewport.rows),
                )
            },
            // Only columns and rows are consumed; a report whose grid did
            // not change would only be dropped by the transport anyway.
            suppressesPixelOnlyResizes: true,
        )
        // The first viewport report means the surface is attached and
        // rendering, so bytes fed to the session are no longer dropped — the
        // earliest safe moment to open the connection. It also means a
        // transport that negotiates size knows the grid before connecting.
        relay.onFirstViewport = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectWhenReady()
            }
        }
        titleTracker.onCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.offerInferredTitle(command)
            }
        }
    }

    /// Accepts a typed line as this session's title, if it is one.
    ///
    /// The viewport check is the safety half: the line has to be visible on
    /// screen at the moment Return was pressed. A prompt reading a password
    /// echoes nothing, so nothing here matches and the old title stands.
    private func offerInferredTitle(_ command: String) {
        guard let screen = session.readViewportText(), screen.contains(command) else { return }
        inferredTitle = command
    }

    /// The scene reached foreground-active; the second half of the
    /// auto-connect gate. Signalled by the scene delegate through the
    /// `TabManager`, and again for tabs created while already active.
    func noteSceneActive() {
        guard !isSceneActive else { return }
        isSceneActive = true
        AppLog.info(.session, "scene active; hasViewport=\(relay.hasViewport) autoConnected=\(hasAutoConnected)")
        connectWhenReady()
    }

    /// Auto-connect fires once, when both halves are true: the surface has
    /// reported a grid (bytes fed earlier would be dropped), and the scene
    /// is active. Waiting for activation keeps daemon work out of the
    /// launch transition — the first viewport reported mid-transition
    /// measures ~49×16, and connecting right then spawned the shell at that
    /// size.
    private func connectWhenReady() {
        guard !hasAutoConnected, isSceneActive, relay.hasViewport else { return }
        hasAutoConnected = true
        connect()
    }

    func noteProcessExit(status: Int32) {
        processExitStatus = status
    }

    /// The first connect takes the session from wherever it is open: a
    /// terminal the user picked from another device's list. Every later
    /// connect — a reconnect above all — leaves a holder alone.
    var takesOverOnFirstConnect = false

    /// The device holding it changed (one device took it from another).
    func noteHolder(_ holder: String) {
        if isHeldElsewhere {
            status = .elsewhere(holder)
        }
    }

    /// The tab went `.elsewhere`. Its own link and the watcher's are two
    /// connections, so the release that would bring it back can arrive
    /// first; the tab installs a check here.
    var onHeldElsewhere: (() -> Void)?

    /// Takes the session from wherever it is open — the tab's Use Here.
    func takeOver() {
        connect(takingOver: true)
    }

    func connect(takingOver: Bool = false) {
        let takingOver = takingOver || takesOverOnFirstConnect
        takesOverOnFirstConnect = false
        reconnectGeneration &+= 1
        // A new connection means a new (or resumed) process; the old exit
        // verdict no longer describes this session.
        processExitStatus = nil
        // A half-typed line does not survive a reconnect: the shell's line
        // editor never saw the bytes that the dropped link ate.
        titleTracker.reset()
        let transport = makeTransport()
        AppLog.info(
            .session,
            "connecting via \(transport.endpointDescription) sceneActive=\(isSceneActive) hasViewport=\(relay.hasViewport)",
        )
        // `relay` weak as well: the relay retains the transport, which
        // retains this closure. A strong capture would close that cycle and
        // defeat the transport's deinit, whose job is to cancel an XPC
        // connection its owner dropped without disconnecting.
        let transferCutByLink = transferCutByLink
        let downloadKeptAcrossLink = downloadKeptAcrossLink
        let session = session
        let outputSignal = outputSignal
        // Per-connection and holds no shared session state, so another client
        // or an older daemon is unaffected.
        // A download the last link dropped is kept for this one: it
        // resumes if this link reaches the same session (`.sessionResumed`).
        let engine = downloadKeptAcrossLink.take() ? (zmodemEngine ?? makeZmodemEngine()) : makeZmodemEngine()
        zmodemEngine = engine
        // The last link dropped mid-transfer: the program on the other end
        // is still in it, and its stream must not land on the screen.
        if transferCutByLink.take() {
            engine?.discardInterruptedTransfer()
        }
        AppLog.info(.zmodem, "connect: zmodem engine \(engine == nil ? "OFF" : "ON") (setting=\(ZmodemSetting.isEnabled))")
        // `engine` weak for the same reason `relay` is: the store holds it
        // strongly, and a strong capture here would outlive teardown.
        transport.onEvent = { [weak self, weak relay, weak engine] event in
            // Output goes straight into the session from the transport's
            // queue — `receive` only takes a lock and enqueues on the
            // session's own serial parse queue, so stream order is the
            // transport's. It used to ride a main-actor Task per chunk, each
            // holding its bytes: under a flood those Tasks queued behind a
            // busy main thread without bound and kept growing after the
            // output stopped. The main actor now hears only that output
            // happened, through at most one pending hop (`OutputSignal`).
            if case let .received(data, replay) = event {
                if let engine, !replay {
                    // Live bytes run through the engine (it renders non-ZMODEM
                    // output and swallows a transfer); replayed scrollback is
                    // historical, so it skips the engine — a stale rz/sz frame
                    // in the buffer must not start a transfer.
                    engine.ingest(data)
                } else {
                    // A transfer in the replay — finished minutes ago, or
                    // cut off by the link that just dropped — is binary
                    // that would cover the screen and retitle the tab.
                    var data = data
                    if replay {
                        let stripped = ZmodemStreamScanner.strip([UInt8](data))
                        if stripped.removed {
                            AppLog.info(.zmodem, "replay: \(data.count - stripped.bytes.count) bytes of a transfer left out")
                            data = Data(stripped.bytes)
                        }
                    }
                    session.receive(data)
                    if outputSignal.noteChunk(byteCount: data.count) {
                        Task { @MainActor [weak self] in
                            self?.noteReceived()
                        }
                    }
                }
                return
            }
            // A transfer cannot outlive the link it ran on — nor a session
            // another device just took, whose bytes now go there.
            switch event {
            case .state(.disconnected), .state(.interrupted):
                switch engine?.suspendForLostLink() {
                case .suspended:
                    downloadKeptAcrossLink.set()
                case .abandoned:
                    transferCutByLink.set()
                    Task { @MainActor [weak self] in
                        self?.finishUpload(.failed(String(localized: "The connection dropped, so the transfer was cancelled.")))
                    }
                case .idle, nil:
                    break
                }
            case let .sessionResumed(resumed):
                if resumed {
                    engine?.resume()
                } else {
                    engine?.abandonSuspended()
                }
            case .state(.heldElsewhere):
                engine?.reset()
            default:
                break
            }
            // Sized here, on the transport's own queue and before the hop
            // to the main actor: the newest grid has to reach the session
            // *behind* the open or attach, and only the relay's record is
            // guaranteed to be the newest. A copy re-sent from the main
            // actor is the one thing that can arrive behind a fresher
            // report — at cold launch the main thread is deep in layout
            // while ghostty's IO thread has already reported the settled
            // grid, and the stale copy landed last: a 49×16 PTY under a
            // 93×32 surface, stuck until the next real resize because the
            // surface reports only changes.
            if case .state(.connected) = event {
                relay?.resendLatestViewport()
            }
            // Output after a state change must be noted *after* it — a
            // `.connected` resets the first-output wait — so the next chunk
            // claims a fresh hop instead of riding one queued before it.
            if case .state = event {
                outputSignal.releaseHop()
            }
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        // Installing the transport primes it with the surface's latest grid,
        // so the open starts at the size the surface has rather than the
        // 80×24 protocol default.
        relay.transport = transport
        transport.connect(takingOver: takingOver)
    }

    func disconnect() {
        reconnectGeneration &+= 1
        reconnectAttempt = 0
        zmodemEngine?.reset()
        _ = downloadKeptAcrossLink.take()
        relay.transport?.disconnect()
        relay.transport = nil
        status = .idle
    }

    func cancelZmodemTransfer() {
        if let fileUpload {
            fileUpload.cancel()
            return
        }
        zmodemEngine?.cancel()
    }

    /// Set when a link drops mid-transfer, taken by the next connect.
    /// Touched from the transport's queue and the main actor.
    private let transferCutByLink = OnceFlag()
    /// Set when a link drops mid-download and the engine kept it, taken by
    /// the next connect, which reuses that engine.
    private let downloadKeptAcrossLink = OnceFlag()

    /// The copy a drop started toward another device, while it runs.
    private var fileUpload: Task<[String?], Never>?

    /// Copies dropped files to the device `endpoint` names, one after
    /// another, and answers with the path each has there — nil for one that
    /// did not get there. Shown on the transfer pill, as an `rz` upload
    /// is: one bar across every file, and the pill's × cancels the lot.
    func uploadDroppedFiles(_ files: [URL], to endpoint: DaemonEndpoint) async -> [String?] {
        // A finished transfer's notice may still be up; only one running
        // stands in the way.
        guard fileUpload == nil, zmodemTransfer.map({ $0.phase != .active }) ?? true else {
            AppLog.warning(.drop, "drop upload refused: another transfer is on screen")
            return files.map { _ in nil }
        }
        // A file whose size cannot be read is not sent at all; sent as
        // empty it would paste a path to nothing.
        let sizes = files.map { url in
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
        }
        let total = sizes.reduce(0) { $0 + ($1 ?? 0) }
        let display = files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) files")
        let start = ZmodemTransferInfo(direction: .upload, name: display, transferred: 0, total: total)
        zmodemTransfer = start
        let throttle = UploadProgressThrottle { [weak self] sent in
            guard let self, var info = zmodemTransfer, info.phase == .active else { return }
            info.transferred = sent
            zmodemTransfer = info
        }
        let task = Task { [weak self] () -> [String?] in
            // Dropped while the tab connects: the pill says so and keeps its
            // ×, and the copy starts once the connection is up.
            if self?.status != .connected {
                self?.zmodemTransfer?.isWaitingForConnection = true
                guard await self?.waitUntilConnected() == true else {
                    if !Task.isCancelled {
                        self?.finishUpload(.failed(String(localized: "The terminal did not connect.")))
                    }
                    return files.map { _ in nil }
                }
                self?.zmodemTransfer?.isWaitingForConnection = false
            }
            var paths: [String?] = []
            var base: UInt64 = 0
            for (file, size) in zip(files, sizes) {
                guard !Task.isCancelled, let size else {
                    paths.append(nil)
                    continue
                }
                let upload = DaemonFileUpload(
                    endpoint: endpoint,
                    file: file,
                    name: file.lastPathComponent,
                    size: size,
                ) { [base] held in
                    throttle.note(base + held)
                }
                do {
                    try await paths.append(upload.run())
                } catch is CancellationError {
                    paths.append(nil)
                } catch {
                    AppLog.error(.drop, "upload of \(file.lastPathComponent) failed: \(error)")
                    await MainActor.run { [weak self] in
                        self?.finishUpload(.failed(error.localizedDescription))
                    }
                    return paths + Array(repeating: nil, count: files.count - paths.count)
                }
                base += size
            }
            return paths
        }
        fileUpload = task
        let paths = await task.value
        fileUpload = nil
        // Cancelled means nothing is pasted, whatever reached the other
        // device before the cancel took.
        if task.isCancelled {
            finishUpload(.cancelled)
            return files.map { _ in nil }
        }
        if zmodemTransfer?.phase == .active {
            finishUpload(.done)
        }
        return paths
    }

    /// Returns once the tab is connected: true then, false if the waiting
    /// task is cancelled or the connection gives up (failed, or the session
    /// is in use elsewhere). Reconnects in between are waited out.
    func waitUntilConnected() async -> Bool {
        for await status in $status.values {
            if Task.isCancelled { return false }
            switch status {
            case .connected: return true
            case .failed, .elsewhere: return false
            case .idle, .connecting: continue
            }
        }
        return false
    }

    private func finishUpload(_ phase: ZmodemTransferPhase) {
        guard var info = zmodemTransfer, info.phase == .active else { return }
        info.isWaitingForConnection = false
        info.phase = phase
        if phase == .done, let total = info.total {
            info.transferred = total
        }
        zmodemTransfer = info
        let notice = info
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: phase == .done ? 2_000_000_000 : 5_000_000_000)
            if self?.zmodemTransfer == notice {
                self?.zmodemTransfer = nil
            }
        }
    }

    /// The engine suppresses its own confirmation for a download, so this one —
    /// posted after the save picker — is what the user sees.
    private func showZmodemSaved(name: String, count: Int) {
        guard zmodemTransfer == nil else { return }
        let display = count > 1 ? String(localized: "\(count) files") : name
        let notice = ZmodemTransferInfo(direction: .download, name: display, transferred: 0, total: nil, phase: .done)
        zmodemTransfer = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.zmodemTransfer == notice {
                self?.zmodemTransfer = nil
            }
        }
    }

    private func makeZmodemEngine() -> ZmodemEngine? {
        guard ZmodemSetting.isEnabled else { return nil }
        let session = session
        let relay = relay
        let outputSignal = outputSignal
        return ZmodemEngine(
            sink: { bytes in relay.send(Data(bytes)) },
            passthrough: { [weak self] bytes in
                let data = Data(bytes)
                session.receive(data)
                if outputSignal.noteChunk(byteCount: data.count) {
                    Task { @MainActor [weak self] in self?.noteReceived() }
                }
            },
            makeWriter: { [weak self] in
                let store = self
                return ZmodemFileBridge.makeReceiveWriter(onSaved: { name, count in
                    Task { @MainActor in store?.showZmodemSaved(name: name, count: count) }
                })
            },
            requestSource: { completion in
                Task { @MainActor in ZmodemFileBridge.requestUploadSource(completion) }
            },
            onState: { [weak self] info in
                Task { @MainActor [weak self] in self?.zmodemTransfer = info }
            },
        )
    }

    private let outputSignal = OutputSignal()
    private var notedChunks = 0

    /// The main actor's half of received output: one call per hop, however
    /// many chunks the session took in since the last one.
    private func noteReceived() {
        let (chunks, bytes) = outputSignal.drain()
        let previous = notedChunks
        notedChunks += chunks
        if previous < 5 || previous / 50 != notedChunks / 50 {
            AppLog.verbose(.session, "received \(chunks) chunk(s), \(bytes) bytes (#\(notedChunks)) status=\(status)")
        }
        noteOutput()
        notePageChanged()
    }

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case .received:
            // Fed to the session on the transport's queue; never hopped.
            break
        case let .processName(name, isShell):
            processName = name
            isShellInForeground = isShell
        case let .currentDirectory(directory):
            currentDirectory = directory
            // The transport only reports changes, so this is one visit —
            // filed under the device whose file system it is.
            if recordsRecentDirectories {
                RecentDirectoryStore.shared.record(directory, onHost: recentDirectoryHostID)
            }
        case let .sessionAttributes(attributes, isResumed):
            onSessionAttributes?(attributes, isResumed)
        case .inputRefused:
            notePasteTruncated()
        case .sessionResumed:
            // Handled on the transport's queue, ahead of the output.
            break
        case let .state(state):
            apply(state)
        }
    }

    private func apply(_ state: TerminalTransportState) {
        switch state {
        case .connecting:
            isShellInForeground = false
            currentDirectory = nil
            clearFirstOutputWait()
            // No status line: the pill overlay already says connecting, and
            // a clean launch should open on the shell's own first line.
            // Only trouble (interruptions, failures) gets written into the
            // terminal.
            status = .connecting
        case .connected:
            AppLog.info(.session, "connected to \(endpointDescription)")
            status = .connected
            reconnectAttempt = 0
            reconnectStartedAt = nil
            awaitFirstOutput()
        case let .interrupted(reason):
            clearFirstOutputWait()
            AppLog.error(.session, "link lost: \(reason ?? "no reason")")
            printStatusLine(String(localized: "Connection lost. Reconnecting…"))
            scheduleReconnect(lastReason: reason)
        case let .heldElsewhere(holder):
            clearFirstOutputWait()
            reconnectAttempt = 0
            AppLog.info(.session, "session held elsewhere\(holder.map { " by \($0)" } ?? "")")
            status = .elsewhere(holder)
            onHeldElsewhere?()
        case let .disconnected(reason):
            clearFirstOutputWait()
            AppLog.error(.session, "disconnected: \(reason ?? "no reason")")
            // Mid-cycle this is a reconnect attempt that could not even
            // establish; keep trying until the attempts run out.
            if reconnectAttempt > 0 {
                scheduleReconnect(lastReason: reason)
                return
            }
            status = reason.map { .failed($0) } ?? .idle
            printStatusLine(reason ?? String(localized: "Disconnected."))
        }
    }

    /// One paced attempt to get the session back, or the final failure once
    /// the attempts are spent. Runs only after `interrupted` — a final
    /// `disconnected` never starts a cycle.
    private func scheduleReconnect(lastReason: String?) {
        if reconnectsPatiently, !NetworkPathWatcher.shared.isSatisfied {
            reconnectStartedAt = nil
        }
        let startedAt = reconnectStartedAt ?? Date()
        reconnectStartedAt = startedAt
        let isSpent = reconnectsPatiently
            ? Date().timeIntervalSince(startedAt) > Self.patientReconnectWindow
            : reconnectAttempt >= Self.reconnectAttemptLimit
        guard !isSpent else {
            reconnectAttempt = 0
            reconnectStartedAt = nil
            let reason = lastReason ?? String(
                localized: "Unable to reconnect to the terminal. Try again or close the tab.",
            )
            status = .failed(reason)
            printStatusLine(reason)
            return
        }
        reconnectAttempt += 1
        status = .connecting
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        AppLog.info(.session, "reconnect attempt \(reconnectAttempt) scheduled")
        let delay = reconnectsPatiently ? Self.patientReconnectDelay(attempt: reconnectAttempt) : Self.reconnectDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, reconnectGeneration == generation else { return }
            connect()
        }
    }

    /// 1, 2, 4, then 5 s, each ±20 % so tabs that lost the same link do
    /// not all knock at once. Short on purpose: the network coming back is
    /// answered at once (`reconnectNow`), and these are for a host that
    /// went away and returns, where 15 s between tries read as hung.
    private static func patientReconnectDelay(attempt: Int) -> UInt64 {
        let base = min(5, pow(2, Double(max(0, attempt - 1))))
        return UInt64(base * Double.random(in: 0.8 ... 1.2) * 1_000_000_000)
    }

    /// Cuts a back-off wait short — the app came forward, which is when a
    /// link that died in the background is worth trying at once.
    func reconnectNowIfWaiting() {
        guard reconnectAttempt > 0, status == .connecting else { return }
        connect()
    }

    /// A session on another device whose link is down tries again now,
    /// with a fresh minute: the network came back, or moved, or the app
    /// came forward. One that already gave up is tried again too — unless
    /// its shell ended, which no reconnect undoes.
    func reconnectNow() {
        guard reconnectsPatiently else { return }
        if hasFailed {
            guard processExitStatus == nil else { return }
            connect()
            return
        }
        guard reconnectAttempt > 0, status == .connecting else { return }
        reconnectStartedAt = nil
        connect()
    }

    /// Starts the wait for the session's first byte. The grace period is
    /// the difference between a launch that opens on the prompt and one
    /// that shows a spinner for a frame; the generation drops a timer
    /// whose connection has since changed.
    private func awaitFirstOutput() {
        hasReceivedOutput = false
        isAwaitingFirstOutput = false
        firstOutputGeneration &+= 1
        let generation = firstOutputGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.firstOutputGrace)
            guard let self, firstOutputGeneration == generation,
                  status == .connected, !hasReceivedOutput else { return }
            isAwaitingFirstOutput = true
            AppLog.info(
                .session,
                "no output \(Self.firstOutputGrace / 1_000_000) ms after connect; showing the shell pill",
            )
        }
    }

    private func notePasteTruncated() {
        isPasteTruncated = true
        pasteNoticeGeneration &+= 1
        let generation = pasteNoticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pasteNoticeDuration)
            guard let self, pasteNoticeGeneration == generation else { return }
            isPasteTruncated = false
        }
    }

    private func clearFirstOutputWait() {
        firstOutputGeneration &+= 1
        isAwaitingFirstOutput = false
    }

    /// Bumped as output arrives, at most once a second with one trailing
    /// bump after a burst, so a row whose second line mirrors the page
    /// (`TerminalTab.secondaryTitle`) re-renders while the page changes
    /// without a redraw per chunk.
    @Published private(set) var pageGeneration: UInt64 = 0
    private var lastPageBump = Date.distantPast
    private var pageBumpScheduled = false

    private func notePageChanged() {
        let now = Date()
        if now.timeIntervalSince(lastPageBump) >= 1 {
            lastPageBump = now
            pageGeneration &+= 1
        } else if !pageBumpScheduled {
            pageBumpScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                pageBumpScheduled = false
                lastPageBump = Date()
                pageGeneration &+= 1
            }
        }
    }

    private func noteOutput() {
        guard !hasReceivedOutput else { return }
        hasReceivedOutput = true
        clearFirstOutputWait()
    }

    /// Dim, bracketed line rendered by the terminal itself.
    ///
    /// Opens with a bare `\r` rather than `\r\n`: consecutive status lines
    /// already end with a newline, so a leading one puts a blank line between
    /// every pair. The carriage return alone still guarantees column zero.
    private func printStatusLine(_ message: String) {
        noteOutput()
        // The page changed even though no transport event fired: a row whose
        // second line mirrors the page would otherwise sit on the state from
        // before this line until the next real output.
        notePageChanged()
        session.receive("\r\u{1b}[2m[iGhostVT] \(message)\u{1b}[0m\r\n")
    }
}

/// Thread-safe indirection between the long-lived terminal session and the
/// transport of the moment. The session's write/resize closures are captured
/// once at init; reconnects swap the transport behind this relay.
///
/// The relay is also the record of the surface's latest grid that outlives
/// any one transport. Every report passes through `updateViewport` on the
/// thread that made it; a transport installed later is primed with the
/// record, and `resendLatestViewport` replays it once a session exists. All
/// three happen under one lock, so no report can slip between a swap and
/// its prime, and no transport ever hears an older size after a newer one.
/// `TerminalTransport.updateViewport` is therefore called with the lock
/// held, and must neither block nor call back into the store.
private final class TransportRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var _transport: TerminalTransport?
    private var _latestViewport: (columns: Int, rows: Int)?
    private var _onFirstViewport: (@Sendable () -> Void)?

    /// Fires once, on the first report. Later reports change nothing the
    /// store tracks — the relay forwards them itself — so they cost no hop
    /// to the main actor.
    var onFirstViewport: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFirstViewport }
        set { lock.lock(); _onFirstViewport = newValue; lock.unlock() }
    }

    /// Whether the surface has reported a grid yet.
    var hasViewport: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _latestViewport != nil
    }

    var transport: TerminalTransport? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _transport
        }
        set {
            lock.lock()
            _transport = newValue
            if let newValue, let viewport = _latestViewport {
                newValue.updateViewport(columns: viewport.columns, rows: viewport.rows)
            }
            lock.unlock()
        }
    }

    func send(_ data: Data) {
        transport?.send(data)
    }

    func updateViewport(columns: Int, rows: Int) {
        lock.lock()
        let isFirst = _latestViewport == nil
        _latestViewport = (columns, rows)
        _transport?.updateViewport(columns: columns, rows: rows)
        let onFirstViewport = isFirst ? _onFirstViewport : nil
        lock.unlock()
        onFirstViewport?()
    }

    /// Hands the current transport the newest grid again — for the moment
    /// its session comes into being, when the transport itself only knows
    /// the size the open or attach was sent with.
    func resendLatestViewport() {
        lock.lock()
        if let viewport = _latestViewport {
            _transport?.updateViewport(columns: viewport.columns, rows: viewport.rows)
        }
        lock.unlock()
    }
}

/// What received output owes the main actor, kept off it. The transport's
/// queue counts every chunk here and schedules a main-actor hop only when
/// none is pending, so however fast output arrives, at most one hop waits —
/// plus one per state change, which releases the claim so output after it
/// is noted after it. The hop drains the counts; the bytes themselves never
/// leave the transport's queue except into the session.
private final class OutputSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hopPending = false
    private var chunks = 0
    private var bytes = 0

    /// Counts a chunk; true when the caller must schedule the hop.
    func noteChunk(byteCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        chunks += 1
        bytes += byteCount
        guard !hopPending else { return false }
        hopPending = true
        return true
    }

    func releaseHop() {
        lock.lock()
        hopPending = false
        lock.unlock()
    }

    /// Run by the hop: the counts since the last one, and the claim given
    /// back so the next chunk schedules another.
    func drain() -> (chunks: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let drained = (chunks, bytes)
        chunks = 0
        bytes = 0
        hopPending = false
        return drained
    }
}

/// At most ten progress updates a second reach the main actor, newest
/// wins: a fast link acknowledges hundreds of parts a second.
private final class UploadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0
    private var isScheduled = false
    private let apply: @MainActor (UInt64) -> Void

    init(apply: @escaping @MainActor (UInt64) -> Void) {
        self.apply = apply
    }

    func note(_ sent: UInt64) {
        let schedule = lock.withLock {
            latest = max(latest, sent)
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            let value = self.lock.withLock {
                self.isScheduled = false
                return self.latest
            }
            self.apply(value)
        }
    }
}

/// A flag one queue sets and another takes, once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.lock()
        isSet = true
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = isSet
        isSet = false
        return value
    }
}
