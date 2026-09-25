//
//  WindowIntents.swift
//  iGhostVT
//

import AppIntents
import Foundation

// The intents that need a window: they open the app (`openAppWhenRun`) and
// act through `ShortcutBridge` on the tabs, never on the daemon directly.

@available(iOS 16.0, macCatalyst 16.0, *)
struct ShowSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Terminal Session"
    static let description = IntentDescription(
        "Opens iGhostVT and shows a terminal session, in a new tab if no tab is showing it.",
        categoryName: "Window",
    )
    static let openAppWhenRun = true

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$session)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutBridge.showSession(session.daemonID)
        return .result()
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct OpenNewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open New Terminal Tab"
    static let description = IntentDescription(
        "Opens iGhostVT with a new tab. The tab runs the program you give, or a shell in the current tab's directory.",
        categoryName: "Window",
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Program",
        description: "A program to run instead of the shell, with its arguments. Leave empty for the default shell.",
    )
    var program: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open a new terminal tab") {
            \.$program
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity?> {
        let arguments = ShellWords.split(program ?? "")
        guard !arguments.isEmpty else {
            // The regular path: the tab opens its own session and inherits
            // the active tab's directory. Its id is not known until it
            // connects, so there is no entity to hand back yet.
            _ = try await ShortcutBridge.openNewTab()
            return .result(value: nil)
        }
        let inherit = ShortcutBridge.activeSessionID()
        let session = try await ShortcutDaemonClient.withConnection { client in
            let id = try await client.openSession(command: arguments, inheritDirectoryFrom: inherit)
            // The daemon attached the new session to this connection. Let
            // go of it explicitly and wait for the reply: the connection's
            // cancel is asynchronous, and a tab whose attach reached the
            // daemon first would be told the session is busy and open a
            // plain shell instead.
            try await client.detachSession(id)
            return try await client.session(id)
        }
        try await ShortcutBridge.showSession(session.id)
        return .result(value: SessionEntity(session))
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SetSessionLockIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Terminal Session"
    static let description = IntentDescription(
        "Locks or unlocks the tab showing a session. A locked tab ignores your input, and the program keeps running.",
        categoryName: "Window",
    )
    static let openAppWhenRun = true

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Lock", default: .interaction)
    var lock: SessionLockMode

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$session) to \(\.$lock)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let tab = try await ShortcutBridge.showSession(session.daemonID)
        tab.lock = lock.tabLock
        return .result()
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open iGhostVT"
    static let description = IntentDescription("Opens iGhostVT.", categoryName: "Window")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
