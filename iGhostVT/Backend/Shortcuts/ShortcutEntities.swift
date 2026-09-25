//
//  ShortcutEntities.swift
//  iGhostVT
//

import AppIntents
import Foundation

/// A daemon session as Shortcuts sees it. The daemon is the book of record
/// — an entity is a `listSessions` row, looked up again on every use, so a
/// session that died between two actions reads as gone rather than stale.
@available(iOS 16.0, macCatalyst 16.0, *)
struct SessionEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Session")
    static let defaultQuery = SessionQuery()

    /// The daemon's id, as a string: `UInt64` cannot identify an entity.
    let id: String

    /// The id the daemon speaks.
    var daemonID: UInt64 {
        UInt64(id) ?? 0
    }

    @Property(title: "Session ID")
    var sessionID: Int

    @Property(title: "Program")
    var program: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Current Directory")
    var currentDirectory: String

    @Property(title: "Columns")
    var columns: Int

    @Property(title: "Rows")
    var rows: Int

    @Property(title: "Shown in a Tab")
    var isAttached: Bool

    @Property(title: "At Prompt")
    var isAtPrompt: Bool

    init(_ session: ShortcutSession) {
        id = String(session.id)
        sessionID = Int(clamping: session.id)
        program = session.processName ?? session.title
        title = session.title
        currentDirectory = session.currentDirectory ?? ""
        columns = Int(session.columns)
        rows = Int(session.rows)
        isAttached = session.isAttached
        isAtPrompt = session.foregroundIsShell ?? false
    }

    var displayRepresentation: DisplayRepresentation {
        let name = program.isEmpty ? String(localized: "Session \(sessionID)") : program
        let subtitle = currentDirectory.isEmpty ? String(localized: "Session \(sessionID)") : currentDirectory
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "terminal"),
        )
    }

    func matches(_ term: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if String(sessionID) == needle {
            return true
        }
        return [program, title, currentDirectory].contains {
            $0.localizedCaseInsensitiveContains(needle)
        }
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SessionQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        let wanted = Set(identifiers)
        return try await loadEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SessionEntity] {
        try await loadEntities().filter { $0.matches(string) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        try await loadEntities()
    }

    private func loadEntities() async throws -> [SessionEntity] {
        try await ShortcutDaemonClient.withConnection { client in
            try await client.listSessions().map(SessionEntity.init)
        }
    }
}

/// The keys a Shortcut can press — the ones a person reaches for from a
/// script: confirm, cancel, interrupt, navigate. Each maps onto a name in
/// the CLI's `send` vocabulary, so the bytes are the CLI's bytes.
@available(iOS 16.0, macCatalyst 16.0, *)
enum TerminalKey: String, AppEnum {
    case enter
    case tab
    case escape
    case space
    case backspace
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case controlA
    case controlC
    case controlD
    case controlE
    case controlL
    case controlR
    case controlU
    case controlZ

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Key")

    static let caseDisplayRepresentations: [TerminalKey: DisplayRepresentation] = [
        .enter: "Return",
        .tab: "Tab",
        .escape: "Escape",
        .space: "Space",
        .backspace: "Delete (Backspace)",
        .delete: "Forward Delete",
        .up: "Up Arrow",
        .down: "Down Arrow",
        .left: "Left Arrow",
        .right: "Right Arrow",
        .home: "Home",
        .end: "End",
        .pageUp: "Page Up",
        .pageDown: "Page Down",
        .controlA: "Control-A (Line Start)",
        .controlC: "Control-C (Interrupt)",
        .controlD: "Control-D (End of Input)",
        .controlE: "Control-E (Line End)",
        .controlL: "Control-L (Clear Screen)",
        .controlR: "Control-R (Search History)",
        .controlU: "Control-U (Clear Line)",
        .controlZ: "Control-Z (Suspend)",
    ]

    /// The CLI's name for this key.
    var keyName: String {
        switch self {
        case .enter: "Enter"
        case .tab: "Tab"
        case .escape: "Escape"
        case .space: "Space"
        case .backspace: "BSpace"
        case .delete: "Delete"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .controlA: "C-a"
        case .controlC: "C-c"
        case .controlD: "C-d"
        case .controlE: "C-e"
        case .controlL: "C-l"
        case .controlR: "C-r"
        case .controlU: "C-u"
        case .controlZ: "C-z"
        }
    }

    var bytes: [UInt8] {
        KeyNames.bytes(for: keyName) ?? []
    }
}

/// A tab's lock, as a Shortcut sets it (`TerminalTab.lock`).
@available(iOS 16.0, macCatalyst 16.0, *)
enum SessionLockMode: String, AppEnum {
    case unlocked
    case interaction
    case keyboard

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lock")

    static let caseDisplayRepresentations: [SessionLockMode: DisplayRepresentation] = [
        .unlocked: "Unlocked",
        .interaction: "Locked",
        .keyboard: "Keyboard Locked",
    ]

    var tabLock: TabLock? {
        switch self {
        case .unlocked: nil
        case .interaction: .interaction
        case .keyboard: .keyboard
        }
    }
}
