import Darwin
import Dispatch
import XPC

/// Owns `ighostvt-mcp`, the MCP server, while its switch is on, and decides
/// which client it may let in.
///
/// The switch is a file (`flagPath`), as remote access's is: present means
/// on, read at launch and written by `setMCPServer`. The server is spawned
/// beside this executable, drops to the session user, listens on loopback
/// only (`MCPConsent.port`), and connects back over XPC for everything it
/// does — admitted for being this child, never by its path, so a copy run by
/// hand reaches nothing. It holds one connection for as long as it runs,
/// which keeps the daemon resident, and exits when that connection goes.
///
/// **Consent is the app's, in Settings.** The server's OAuth consent page is
/// served on the same port anything on the device can reach, so a form there
/// proves nothing: any process could fetch the page and post its own
/// approval. Instead the server asks here (`beginMCPConsent`) and waits for
/// the answer (`mcpConsentState`), and only the app may answer
/// (`answerMCPConsent`) — and only while its settings page is up
/// (`setMCPConsentWindow`). With no window open a request is refused before
/// anyone is asked, so nothing running in the background can raise one.
/// Each request carries a code the consent page shows too, so the person can
/// tell their client's request from one raised beside it. The server also
/// says how many clients hold a token (`reportMCPClients`), which the
/// status carries so Settings offers Forget only when there is someone to
/// forget.
///
/// Nothing here reads more of a message than its operation and the fields
/// named above; the state is a handful of small entries.
final class MCPSupervisor {
    static let executableName = "ighostvt-mcp"
    private static let closeOnExecByDefault: Int16 = 0x4000

    enum Sender {
        case app
        case otherClient
        case server
    }

    private struct Request {
        var clientName: String
        var redirect: String
        var code: String
        var expiresAt: Double
        var state: MCPConsentState
        /// When it stopped waiting; kept a little longer so the server's
        /// next question still finds the answer.
        var settledAt: Double = 0
    }

    private let queue: DispatchQueue
    let executablePath: String

    private var childPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var lastSpawn: Double = 0
    private var quickExits = 0
    private var respawnScheduled = false
    /// The next start wipes the clients and tokens the server kept.
    private var forgetOnNextStart = false

    /// What the server last reported (`reportMCPClients`); zero once
    /// Forget is asked, before the restarted server says so itself.
    private var authorizedClients: UInt64 = 0

    private var windowOpenUntil: Double = 0
    private var requests: [UInt64: Request] = [:]
    private var nextRequestID = UInt64(arc4random()) + 1

    init(queue: DispatchQueue, executablePath: String) {
        self.queue = queue
        self.executablePath = executablePath
    }

    // MARK: - The switch

    /// Beside remote access's switch, and for the same reason: on the device
    /// a directory only root can write, since its mere presence opens a
    /// listener.
    static let flagPath: String = {
        #if os(macOS)
            let log = iGhostVTProtocol.daemonLogPath
            return String(log[..<(log.lastIndex(of: "/") ?? log.startIndex)]) + "/ighostvtd.mcp-server"
        #else
            return RuntimeEnvironment.resolve(RuntimeEnvironment.bootstrapPath("/var/lib/ighostvt/mcp-server"))
        #endif
    }()

    private static let flagName = ConfinedFile.split(flagPath)?.name ?? ""

    var isEnabled: Bool {
        guard let directory = Self.openFlagDirectory() else { return false }
        defer { close(directory) }
        var info = stat()
        return fstatat(directory, Self.flagName, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func openFlagDirectory() -> Int32? {
        guard let (path, _) = ConfinedFile.split(flagPath) else { return nil }
        let directory = ConfinedFile.openDirectory(path)
        guard directory >= 0 else { return nil }
        guard ConfinedFile.isPrivate(directory) else {
            close(directory)
            DaemonFileLog.log("mcp: \(path) is writable by others, so the switch reads off")
            return nil
        }
        return directory
    }

    /// The server's pid until it is reaped, 0 otherwise.
    var serverProcessID: pid_t {
        childPID
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        DaemonFileLog.log("mcp server is on, starting it")
        spawnOrRetry()
    }

    // MARK: - Requests

    /// One MCP operation from a peer, answered here.
    func handle(_ message: xpc_object_t, from sender: Sender) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation))
        guard let operation, Self.may(sender, send: operation) else {
            return Self.refuse(reply, .invalidRequest, "Not allowed from this client.")
        }
        let now = Self.now()
        prune(now: now)
        switch operation {
        case .mcpStatus:
            fillStatus(reply)
        case .setMCPServer:
            setEnabled(xpc_dictionary_get_bool(message, iGhostVTWireKey.enabled))
            fillStatus(reply)
        case .setMCPConsentWindow:
            if xpc_dictionary_get_bool(message, iGhostVTWireKey.open) {
                windowOpenUntil = now + MCPConsent.windowSeconds
            } else {
                windowOpenUntil = 0
                // Closed by the person leaving the page: nothing waiting
                // was allowed, so it is refused.
                settleWaiting(as: .denied, now: now)
            }
        case .mcpConsentRequests:
            fillRequests(reply, now: now)
        case .answerMCPConsent:
            let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.requestID)
            guard now < windowOpenUntil, var request = requests[id], request.state == .pending else {
                return Self.refuse(reply, .invalidRequest, "That request is no longer waiting.")
            }
            request.state = xpc_dictionary_get_bool(message, iGhostVTWireKey.allow) ? .allowed : .denied
            request.settledAt = now
            requests[id] = request
            DaemonFileLog.log("mcp: consent \(id) for \(request.clientName) \(request.state.rawValue)")
        case .beginMCPConsent:
            guard now < windowOpenUntil else {
                return Self.refuse(reply, .operationFailed, "Open iGhostVT Settings to approve a new client.")
            }
            guard requests.values.filter({ $0.state == .pending }).count < MCPConsent.maximumPendingRequests else {
                return Self.refuse(reply, .operationFailed, "Too many requests are waiting.")
            }
            let id = nextRequestID
            nextRequestID &+= 1
            let code = Self.consentCode()
            requests[id] = Request(
                clientName: Self.field(iGhostVTWireKey.clientName, in: message),
                redirect: Self.field(iGhostVTWireKey.redirect, in: message),
                code: code,
                expiresAt: now + MCPConsent.requestSeconds,
                state: .pending,
            )
            xpc_dictionary_set_uint64(reply, iGhostVTWireKey.requestID, id)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.consentCode, code)
        case .mcpConsentState:
            let id = xpc_dictionary_get_uint64(message, iGhostVTWireKey.requestID)
            let state = requests[id]?.state ?? .expired
            xpc_dictionary_set_string(reply, iGhostVTWireKey.mcpConsent, state.rawValue)
        case .forgetMCPClients:
            forgetClients()
            authorizedClients = 0
            fillStatus(reply)
        case .reportMCPClients:
            authorizedClients = xpc_dictionary_get_uint64(message, iGhostVTWireKey.mcpClients)
        default:
            return Self.refuse(reply, .invalidRequest, "Not an MCP operation.")
        }
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, iGhostVTReplyCode.success.rawValue)
        return reply
    }

    static func isMCPOperation(_ code: UInt64) -> Bool {
        (iGhostVTOperation.mcpStatus.rawValue ... iGhostVTOperation.reportMCPClients.rawValue).contains(code)
    }

    private static func may(_ sender: Sender, send operation: iGhostVTOperation) -> Bool {
        switch operation {
        case .mcpStatus:
            true
        case .setMCPServer, .setMCPConsentWindow, .mcpConsentRequests, .answerMCPConsent, .forgetMCPClients:
            sender == .app
        case .beginMCPConsent, .mcpConsentState, .reportMCPClients:
            sender == .server
        default:
            false
        }
    }

    private func fillStatus(_ reply: xpc_object_t) {
        let enabled = isEnabled
        let state: MCPServerState = !enabled ? .off : (childPID > 0 ? .running : .starting)
        xpc_dictionary_set_bool(reply, iGhostVTWireKey.enabled, enabled)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.mcpState, state.rawValue)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.port, UInt64(MCPConsent.port))
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.mcpClients, authorizedClients)
    }

    private func fillRequests(_ reply: xpc_object_t, now: Double) {
        let list = xpc_array_create(nil, 0)
        let wall = Double(time(nil))
        for (id, request) in requests.sorted(by: { $0.key < $1.key }) where request.state == .pending {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(entry, iGhostVTWireKey.requestID, id)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.clientName, request.clientName)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.redirect, request.redirect)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.consentCode, request.code)
            xpc_dictionary_set_int64(entry, iGhostVTWireKey.expiresAt, Int64(wall + request.expiresAt - now))
            xpc_array_append_value(list, entry)
        }
        xpc_dictionary_set_value(reply, iGhostVTWireKey.requests, list)
    }

    /// Unanswered requests run out; answered ones are dropped a minute
    /// after, once the server has surely asked; a lapsed window lets the
    /// waiting ones run out with it.
    private func prune(now: Double) {
        if windowOpenUntil > 0, now >= windowOpenUntil {
            windowOpenUntil = 0
            settleWaiting(as: .expired, now: now)
        }
        for (id, request) in requests {
            if request.state == .pending, now >= request.expiresAt {
                requests[id]?.state = .expired
                requests[id]?.settledAt = now
            } else if request.state != .pending, now - request.settledAt > 60 {
                requests.removeValue(forKey: id)
            }
        }
    }

    private func settleWaiting(as state: MCPConsentState, now: Double) {
        for (id, request) in requests where request.state == .pending {
            requests[id]?.state = state
            requests[id]?.settledAt = now
        }
    }

    private static func field(_ key: String, in message: xpc_object_t) -> String {
        guard let pointer = xpc_dictionary_get_string(message, key) else { return "" }
        let text = String(cString: pointer)
        guard text.utf8.count > MCPConsent.maximumFieldLength else { return text }
        var cut = ""
        for character in text {
            guard cut.utf8.count + String(character).utf8.count <= MCPConsent.maximumFieldLength else { break }
            cut.append(character)
        }
        return cut
    }

    /// Six digits, zero-padded: read off the consent page and the alert
    /// side by side, never typed.
    private static func consentCode() -> String {
        var digits = String(arc4random_uniform(1_000_000))
        while digits.utf8.count < 6 {
            digits = "0" + digits
        }
        return digits
    }

    private static func refuse(_ reply: xpc_object_t, _ code: iGhostVTReplyCode, _ message: String) -> xpc_object_t {
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, message)
        return reply
    }

    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    // MARK: - The child

    private func setEnabled(_ enabled: Bool) {
        let directory = Self.openFlagDirectory()
        defer { directory.map { _ = close($0) } }
        if enabled {
            if let directory {
                let descriptor = ConfinedFile.open(Self.flagName, in: directory, flags: O_WRONLY | O_CREAT)
                if descriptor >= 0 {
                    close(descriptor)
                }
            }
            DaemonFileLog.log("mcp server turned on")
            quickExits = 0
            if childPID == 0 {
                spawnOrRetry()
            }
        } else {
            if let directory {
                unlinkat(directory, Self.flagName, 0)
            }
            DaemonFileLog.log("mcp server turned off")
            windowOpenUntil = 0
            settleWaiting(as: .denied, now: Self.now())
            stop()
        }
    }

    /// The next server wipes what it kept; with the switch off a one-off
    /// run does it now.
    private func forgetClients() {
        DaemonFileLog.log("mcp: forgetting every authorized client")
        if childPID > 0 {
            forgetOnNextStart = true
            stop()
        } else if isEnabled {
            forgetOnNextStart = true
            spawnOrRetry()
        } else {
            _ = launch([executablePath, "revoke-all"])
        }
    }

    private func stop() {
        guard childPID > 0 else { return }
        kill(childPID, SIGTERM)
    }

    private func spawnOrRetry() {
        guard childPID == 0 else { return }
        var arguments = [executablePath, "serve"]
        if forgetOnNextStart {
            arguments.append("--forget")
        }
        guard let pid = launch(arguments) else {
            scheduleRespawn()
            return
        }
        forgetOnNextStart = false
        childPID = pid
        lastSpawn = Self.now()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            self?.reap()
        }
        self.exitSource = exitSource
        exitSource.activate()
        DaemonFileLog.log("mcp server spawned as pid \(pid)")
    }

    /// Spawned with the standard descriptors and nothing else.
    private func launch(_ arguments: [String]) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0 ... 2 where fcntl(descriptor, F_GETFD) >= 0 {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Self.closeOnExecByDefault)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &actions, &attributes, argv, environ)
        guard status == 0 else {
            DaemonFileLog.log("mcp spawn of \(executablePath) failed: \(String(cString: strerror(status)))")
            return nil
        }
        if arguments.count > 1, arguments[1] != "serve" {
            // A one-off: reaped when it is done, never respawned.
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [source] in
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                source.cancel()
            }
            source.activate()
        }
        return pid
    }

    /// Polled: XNU posts the exit before the child is waitable.
    private func reap(attempt: Int = 0) {
        guard childPID > 0 else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 {
            let delay: DispatchTimeInterval = attempt < 100 ? .milliseconds(20) : .seconds(1)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reap(attempt: attempt + 1)
            }
            return
        }
        exitSource?.cancel()
        exitSource = nil
        childPID = 0
        quickExits = Self.now() - lastSpawn < 10 ? quickExits + 1 : 0
        DaemonFileLog.log("mcp server exited (status \(status))")
        if isEnabled {
            scheduleRespawn()
        }
    }

    /// Two seconds, doubling while the server keeps exiting soon after it
    /// starts (its port taken, say), up to a minute.
    private func scheduleRespawn() {
        guard !respawnScheduled else { return }
        respawnScheduled = true
        let seconds = min(60, 2 << min(quickExits, 5))
        queue.asyncAfter(deadline: .now() + .seconds(forgetOnNextStart ? 0 : seconds)) { [weak self] in
            guard let self else { return }
            respawnScheduled = false
            guard isEnabled, childPID == 0 else { return }
            spawnOrRetry()
        }
    }
}
