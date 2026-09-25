//
//  iGhostVTShortcuts.swift
//  iGhostVT
//

import AppIntents

/// The actions Siri and the Shortcuts app offer by name. The primitives
/// (Send Key, Wait for Prompt, Is Busy, Get Directory, Lock) stay out: they
/// are building blocks for the editor, not things to say out loud. Every
/// intent is available in the Shortcuts app either way.
@available(iOS 17.0, macCatalyst 17.0, *)
struct iGhostVTShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run a command in \(.applicationName)",
                "Run a terminal command in \(.applicationName)",
            ],
            shortTitle: "Run Command",
            systemImageName: "terminal",
        )
        AppShortcut(
            intent: NewSessionIntent(),
            phrases: [
                "Start a new session in \(.applicationName)",
                "Start a shell in \(.applicationName)",
            ],
            shortTitle: "New Session",
            systemImageName: "plus.rectangle.on.rectangle",
        )
        AppShortcut(
            intent: SendTextIntent(),
            phrases: [
                "Send text to \(.applicationName)",
                "Type into \(.applicationName)",
            ],
            shortTitle: "Send Text",
            systemImageName: "keyboard",
        )
        AppShortcut(
            intent: GetScreenTextIntent(),
            phrases: [
                "Get the screen text from \(.applicationName)",
                "What is on the screen in \(.applicationName)",
            ],
            shortTitle: "Screen Text",
            systemImageName: "text.alignleft",
        )
        AppShortcut(
            intent: ListSessionsIntent(),
            phrases: [
                "List sessions in \(.applicationName)",
                "What is running in \(.applicationName)",
            ],
            shortTitle: "List Sessions",
            systemImageName: "list.bullet.rectangle",
        )
        AppShortcut(
            intent: ShowSessionIntent(),
            phrases: [
                "Show a session in \(.applicationName)",
                "Open a terminal session in \(.applicationName)",
            ],
            shortTitle: "Show Session",
            systemImageName: "macwindow",
        )
        AppShortcut(
            intent: OpenNewTabIntent(),
            phrases: [
                "Open a new tab in \(.applicationName)",
                "New terminal tab in \(.applicationName)",
            ],
            shortTitle: "New Tab",
            systemImageName: "plus.square.on.square",
        )
        AppShortcut(
            intent: KillSessionIntent(),
            phrases: [
                "End a session in \(.applicationName)",
                "Kill a terminal session in \(.applicationName)",
            ],
            shortTitle: "End Session",
            systemImageName: "xmark.rectangle",
        )
    }
}
