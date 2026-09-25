//
//  KeyShortcuts.swift
//  iGhostVT
//

import UIKit

/// The sections Settings ▸ Keyboard ▸ Shortcuts lists the keys under.
/// Grouping only: every shortcut has its own switch.
enum ShortcutGroup: CaseIterable {
    /// Opening, closing, and switching tabs and windows.
    case tabs
    /// Settings, the sidebar, the switcher, export, the locks.
    case interface
    /// Font size and clear screen — ghostty's own actions, which the app
    /// fronts so the size preference follows.
    case terminal

    var title: String {
        switch self {
        case .tabs: NSLocalizedString("Tabs", comment: "Settings: section of the tab and window shortcuts")
        case .interface: NSLocalizedString("Interface", comment: "Settings: section of the interface shortcuts")
        case .terminal: NSLocalizedString("Terminal", comment: "Settings: section of the terminal shortcuts")
        }
    }
}

/// One key the app claims: what it does, which chord, and where Settings
/// lists it. `KeyShortcuts.all` is the list; `AppMenus` turns each into
/// its menu element, and `LockableTerminalView` intercepts the chord before
/// the terminal can eat it — the library's `pressesBegan` swallows every
/// hardware key without calling `super`, so with a terminal focused UIKit
/// never reaches the menu's key commands on its own.
///
/// A shortcut the user switched off hands its key to the terminal like any
/// other key and loses the key beside its menu item; nothing is rebound.
/// A hidden alias (⌘N for New Tab) follows the switch of its listed twin.
struct KeyShortcut {
    /// The switch's name in UserDefaults; an alias carries its twin's.
    let id: String
    /// The menu item's title, localized. Aliases are never listed.
    let title: String
    let action: Selector
    let input: String
    let modifiers: UIKeyModifierFlags
    let group: ShortcutGroup
    /// The tab index Go to Tab carries; `nil` for every other shortcut.
    let propertyList: Int?
    let isHidden: Bool

    var defaultsKey: String {
        "Shortcut.\(id)"
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The chord the way a menu prints it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.alternate) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        switch input {
        case "\t": text += "⇥"
        default: text += input.uppercased()
        }
        return text
    }

    /// The chord as a press reports it: the unshifted key with Shift in the
    /// flags (`+` is ⇧= on the key), the shape `matches` compares.
    @MainActor
    fileprivate var normalized: (input: String, modifiers: UIKeyModifierFlags) {
        if let base = KeyShortcuts.unshifted[input] {
            return (base, modifiers.union(.shift))
        }
        return (input.lowercased(), modifiers)
    }
}

@MainActor
enum KeyShortcuts {
    /// How many tabs Go to Tab names by position (⌘1–⌘8); the ninth key is
    /// Last Tab. `AppMenus` builds its submenu from the same count.
    static let numberedTabCount = 8

    private typealias R = AppCommandResponder

    private static func L(_ key: String, _ comment: String) -> String {
        NSLocalizedString(key, comment: comment)
    }

    private static func listed(
        _ id: String,
        _ title: String,
        _ action: Selector,
        _ input: String,
        _ modifiers: UIKeyModifierFlags,
        _ group: ShortcutGroup,
        propertyList: Int? = nil,
    ) -> KeyShortcut {
        KeyShortcut(
            id: id,
            title: title,
            action: action,
            input: input,
            modifiers: modifiers,
            group: group,
            propertyList: propertyList,
            isHidden: false,
        )
    }

    private static func alias(
        of id: String,
        _ action: Selector,
        _ input: String,
        _ modifiers: UIKeyModifierFlags,
        _ group: ShortcutGroup,
    ) -> KeyShortcut {
        KeyShortcut(
            id: id,
            title: "",
            action: action,
            input: input,
            modifiers: modifiers,
            group: group,
            propertyList: nil,
            isHidden: true,
        )
    }

    static let all: [KeyShortcut] = {
        var list: [KeyShortcut] = [
            // Tabs and windows.
            listed(
                "newTab",
                L("New Tab", "Menu item: opens a new terminal tab"),
                #selector(R.newTab(_:)),
                "t",
                .command,
                .tabs,
            ),
            alias(of: "newTab", #selector(R.newTab(_:)), "n", .command, .tabs),
            listed(
                "newWindow",
                L("New Window", "Menu item: opens a new window"),
                #selector(R.newWindow(_:)),
                "n",
                [.command, .shift],
                .tabs,
            ),
            listed(
                "closeTab",
                L("Close Tab", "Menu item: closes the active terminal tab"),
                #selector(R.closeTab(_:)),
                "w",
                .command,
                .tabs,
            ),
            listed(
                "closeWindow",
                L("Close Window", "Menu item: closes the window"),
                #selector(R.closeWindow(_:)),
                "w",
                [.command, .shift],
                .tabs,
            ),
            listed(
                "previousTab",
                L("Show Previous Tab", "Menu item: activates the tab before the current one"),
                #selector(R.showPreviousTab(_:)),
                "\t",
                [.control, .shift],
                .tabs,
            ),
            alias(of: "previousTab", #selector(R.showPreviousTab(_:)), "[", [.command, .shift], .tabs),
            listed(
                "nextTab",
                L("Show Next Tab", "Menu item: activates the tab after the current one"),
                #selector(R.showNextTab(_:)),
                "\t",
                .control,
                .tabs,
            ),
            alias(of: "nextTab", #selector(R.showNextTab(_:)), "]", [.command, .shift], .tabs),
        ]
        for number in 1 ... numberedTabCount {
            list.append(listed(
                "selectTab.\(number)",
                String.localizedStringWithFormat(
                    L("Tab %d", "Menu item: switches to the tab at this position; %d is the position"),
                    number,
                ),
                #selector(R.selectTab(_:)),
                String(number),
                .command,
                .tabs,
                propertyList: number - 1,
            ))
        }
        list += [
            listed(
                "selectTab.last",
                L("Last Tab", "Menu item: switches to the last tab"),
                #selector(R.selectTab(_:)),
                "9",
                .command,
                .tabs,
                propertyList: AppMenus.lastTabIndex,
            ),
            // Interface.
            listed(
                "settings",
                L("Settings… (menu)", "Menu item: opens the app's settings; the English text is “Settings…”"),
                #selector(R.showSettings(_:)),
                ",",
                .command,
                .interface,
            ),
            listed(
                "sidebar",
                L("Show Sidebar", "Menu item: shows the tab sidebar"),
                #selector(R.toggleTabSidebar(_:)),
                "s",
                [.command, .control],
                .interface,
            ),
            alias(of: "sidebar", #selector(R.toggleTabSidebar(_:)), "l", [.command, .shift], .interface),
            listed(
                "switcher",
                L("Show All Tabs", "Menu item: opens the tab overview"),
                #selector(R.toggleTabSwitcher(_:)),
                "\\",
                [.command, .shift],
                .interface,
            ),
            listed(
                "exportText",
                L("Export Text…", "Menu item: shares the visible terminal text as a file"),
                #selector(R.exportTabText(_:)),
                "s",
                [.command, .shift],
                .interface,
            ),
            listed(
                "lockTab",
                L("Lock Tab", "Menu item: toggles the tab's input lock"),
                #selector(R.toggleTabLock(_:)),
                "l",
                [.command, .alternate],
                .interface,
            ),
        ]
        // The keyboard lock is not offered on the Mac (`TabContextMenu`
        // has the reasoning); neither is its key.
        #if !targetEnvironment(macCatalyst)
            list.append(listed(
                "lockKeyboard",
                L("Lock Keyboard", "Menu item: toggles the tab's keyboard lock"),
                #selector(R.toggleKeyboardLock(_:)),
                "k",
                [.command, .alternate],
                .interface,
            ))
        #endif
        list += [
            // Terminal.
            listed(
                "biggerText",
                L("Bigger", "Menu item: increases the terminal font size"),
                #selector(R.increaseFontSize(_:)),
                "+",
                .command,
                .terminal,
            ),
            alias(of: "biggerText", #selector(R.increaseFontSize(_:)), "=", .command, .terminal),
            listed(
                "smallerText",
                L("Smaller", "Menu item: decreases the terminal font size"),
                #selector(R.decreaseFontSize(_:)),
                "-",
                .command,
                .terminal,
            ),
            listed(
                "actualSize",
                L("Actual Size", "Menu item: resets the terminal font size"),
                #selector(R.resetFontSize(_:)),
                "0",
                .command,
                .terminal,
            ),
            listed(
                "clearScreen",
                L("Clear Screen", "Menu item: clears the terminal screen and scrollback"),
                #selector(R.clearScreen(_:)),
                "k",
                .command,
                .terminal,
            ),
        ]
        return list
    }()

    static func shortcut(_ action: Selector, propertyList: Int? = nil) -> KeyShortcut {
        all.first {
            $0.action == action && !$0.isHidden && $0.propertyList == propertyList
        }!
    }

    static func alias(_ action: Selector) -> KeyShortcut {
        all.first { $0.action == action && $0.isHidden }!
    }

    /// What Settings lists under a section: the listed shortcuts, in
    /// menu order.
    static func listed(in group: ShortcutGroup) -> [KeyShortcut] {
        all.filter { $0.group == group && !$0.isHidden }
    }

    /// Flips one switch and rebuilds the menu, so the menu bar and the
    /// hold-⌘ overlay stop (or resume) claiming the key at once.
    static func setEnabled(_ enabled: Bool, for shortcut: KeyShortcut) {
        UserDefaults.standard.set(enabled, forKey: shortcut.defaultsKey)
        UIMenuSystem.main.setNeedsRebuild()
    }

    // MARK: - Matching a press

    // ponytail: the shifted glyphs of a US layout; a press also offers the
    // key's HID name below, which is what a non-US layout falls back on.
    fileprivate static let unshifted: [String: String] = [
        "+": "=", "_": "-", "|": "\\", "{": "[", "}": "]", "<": ",", ">": ".",
        "?": "/", ":": ";", "\"": "'", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]

    private static let hidNames: [UIKeyboardHIDUsage: String] = [
        .keyboardTab: "\t", .keyboardBackslash: "\\", .keyboardOpenBracket: "[", .keyboardCloseBracket: "]",
        .keyboardEqualSign: "=", .keyboardHyphen: "-", .keyboardComma: ",", .keyboardPeriod: ".",
        .keyboardSemicolon: ";", .keyboardQuote: "'", .keyboardSlash: "/", .keyboardGraveAccentAndTilde: "`",
    ]

    /// The enabled shortcut this press is, if it is one. Compared unshifted
    /// with Shift in the flags, on every spelling a press carries: the
    /// characters, the characters ignoring modifiers, and the key's HID
    /// name, so ⇧⌘\ matches whether the press says "|" or "\".
    static func shortcut(for key: UIKey) -> KeyShortcut? {
        let modifiers = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
        guard !modifiers.isEmpty else { return nil }
        var spellings: Set<String> = []
        for text in [key.characters, key.charactersIgnoringModifiers] where text.count == 1 {
            spellings.insert(unshifted[text] ?? text.lowercased())
        }
        if let name = hidNames[key.keyCode] {
            spellings.insert(name)
        }
        return all.first { shortcut in
            guard shortcut.isEnabled else { return false }
            let wanted = shortcut.normalized
            return wanted.modifiers == modifiers && spellings.contains(wanted.input)
        }
    }
}
