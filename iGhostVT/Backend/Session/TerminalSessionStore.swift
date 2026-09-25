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
    }

    @Published private(set) var status: Status = .idle

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
    private var hasReceivedOutput = false
    private var firstOutputGeneration: UInt64 = 0
    private static let firstOutputGrace: UInt64 = 1_000_000_000

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
    private var hasAutoConnected = false
    private var isSceneActive = false
    private let makeTransport: () -> TerminalTransport

    /// Reconnect-after-interruption state. The daemon may still hold the
    /// session when the link drops (its KeepAlive restart, mostly), so a few
    /// paced attempts reattach and resume before anything is declared failed.
    /// The generation invalidates a scheduled attempt when the user connects
    /// or disconnects by hand in the meantime.
    private var reconnectAttempt = 0
    private var reconnectGeneration: UInt64 = 0
    private static let reconnectAttemptLimit = 5
    private static let reconnectDelay: UInt64 = 1_000_000_000

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

    func connect() {
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
        transport.onEvent = { [weak self, weak relay] event in
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
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        // Installing the transport primes it with the surface's latest grid,
        // so the open starts at the size the surface has rather than the
        // 80×24 protocol default.
        relay.transport = transport
        transport.connect()
    }

    func disconnect() {
        reconnectGeneration &+= 1
        reconnectAttempt = 0
        relay.transport?.disconnect()
        relay.transport = nil
        status = .idle
    }

    private var receivedChunks = 0

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case let .received(data):
            receivedChunks += 1
            if receivedChunks <= 5 || receivedChunks % 50 == 0 {
                AppLog.verbose(.session, "received chunk #\(receivedChunks) bytes=\(data.count) status=\(status)")
            }
            noteOutput()
            notePageChanged()
            session.receive(data)
        case let .processName(name, isShell):
            processName = name
            isShellInForeground = isShell
        case let .currentDirectory(directory):
            currentDirectory = directory
            // The transport only reports changes, so this is one visit.
            RecentDirectoryStore.shared.record(directory)
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
            awaitFirstOutput()
        case let .interrupted(reason):
            clearFirstOutputWait()
            AppLog.error(.session, "link lost: \(reason ?? "no reason")")
            printStatusLine(String(localized: "Connection lost. Reconnecting…"))
            scheduleReconnect(lastReason: reason)
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
        guard reconnectAttempt < Self.reconnectAttemptLimit else {
            reconnectAttempt = 0
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.reconnectDelay)
            guard let self, reconnectGeneration == generation else { return }
            connect()
        }
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
