//
//  KeyboardBarStore.swift
//  iGhostVT
//

import Foundation
import GhosttyTerminal

/// One key of the keyboard accessory bar, as the settings editor sees it.
/// Mirrors `TerminalInputAccessoryItem` with a stable string code per case so
/// the user's arrangement survives in `UserDefaults`.
enum KeyboardBarKey: Hashable {
    case esc
    case tab
    case ctrl
    case alt
    case command
    case arrowLeft
    case arrowUp
    case arrowDown
    case arrowRight
    case paste
    case divider
    case symbol(String)

    var code: String {
        switch self {
        case .esc: "esc"
        case .tab: "tab"
        case .ctrl: "ctrl"
        case .alt: "alt"
        case .command: "command"
        case .arrowLeft: "left"
        case .arrowUp: "up"
        case .arrowDown: "down"
        case .arrowRight: "right"
        case .paste: "paste"
        case .divider: "divider"
        case let .symbol(symbol): "sym:\(symbol)"
        }
    }

    init?(code: String) {
        switch code {
        case "esc": self = .esc
        case "tab": self = .tab
        case "ctrl": self = .ctrl
        case "alt": self = .alt
        case "command": self = .command
        case "left": self = .arrowLeft
        case "up": self = .arrowUp
        case "down": self = .arrowDown
        case "right": self = .arrowRight
        case "paste": self = .paste
        case "divider": self = .divider
        default:
            guard code.hasPrefix("sym:") else { return nil }
            let symbol = String(code.dropFirst(4))
            guard !symbol.isEmpty else { return nil }
            self = .symbol(symbol)
        }
    }

    // The accessory bar itself is a software-keyboard fixture, and the
    // library only defines it off Catalyst; the arrangement store above
    // still compiles everywhere so settings stay portable.
    #if !targetEnvironment(macCatalyst)
        var accessoryItem: TerminalInputAccessoryItem {
            switch self {
            case .esc: .esc
            case .tab: .tab
            case .ctrl: .ctrl
            case .alt: .alt
            case .command: .command
            case .arrowLeft: .arrowLeft
            case .arrowUp: .arrowUp
            case .arrowDown: .arrowDown
            case .arrowRight: .arrowRight
            case .paste: .paste
            case .divider: .divider
            case let .symbol(symbol): .symbol(symbol)
            }
        }

        /// SF Symbol shown on the bar button, straight from the library's own
        /// mapping so the editor can never drift from what the bar renders;
        /// `nil` means the button shows the symbol text itself.
        var systemImage: String? {
            accessoryItem.systemImage
        }
    #endif

    var displayName: String {
        switch self {
        case .esc: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .ctrl: String(localized: "Control")
        case .alt: String(localized: "Option")
        case .command: String(localized: "Command")
        case .arrowLeft: String(localized: "Left Arrow")
        case .arrowUp: String(localized: "Up Arrow")
        case .arrowDown: String(localized: "Down Arrow")
        case .arrowRight: String(localized: "Right Arrow")
        case .paste: String(localized: "Paste")
        case .divider: String(localized: "Divider")
        case let .symbol(symbol):
            String(
                format: NSLocalizedString("Key “%@”", comment: "A symbol key of the accessory bar"),
                symbol,
            )
        }
    }
}

/// App-wide arrangement of the keyboard accessory bar: which keys it shows
/// and in what order. Every window's tabs follow it live.
@MainActor
final class KeyboardBarStore: ObservableObject {
    static let shared = KeyboardBarStore()

    /// Settings ▸ Accessory Keys ▸ Hide with Hardware Keyboard: the bar
    /// stays down while a hardware keyboard is connected
    /// (`LockableTerminalView.inputAccessoryView`).
    static let hidesWithHardwareKeyboardKey = "KeyboardBar.hidesWithHardwareKeyboard"

    static var hidesWithHardwareKeyboard: Bool {
        UserDefaults.standard.bool(forKey: hidesWithHardwareKeyboardKey)
    }

    /// One row of the arrangement. The identity is per instance, not per key,
    /// so repeated dividers reorder independently.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let key: KeyboardBarKey
    }

    @Published private(set) var entries: [Entry]

    private static let defaultsKey = "KeyboardBar.enabledKeys"

    /// The library's `TerminalInputAccessoryItem.defaultItems`, spelled in
    /// codes. Kept in this vocabulary so a persisted arrangement and the
    /// default one load through the same path.
    private static let defaultCodes = [
        "esc", "tab", "ctrl", "alt", "command", "divider",
        "left", "up", "down", "right", "divider",
        "sym:|", "sym:/", "sym:~", "sym:-", "sym:_",
        "sym:`", "sym:'", "sym:\"", "paste",
    ]

    /// Every non-divider key the editor offers, in the order the "more keys"
    /// list presents them. Keys already on the bar are filtered out.
    private static let catalog: [KeyboardBarKey] = [
        .esc, .tab, .ctrl, .alt, .command,
        .arrowLeft, .arrowUp, .arrowDown, .arrowRight, .paste,
    ] + [
        "|", "/", "~", "-", "_", "`", "'", "\"",
        ";", ":", ",", ".", "=", "+", "*", "&",
        "[", "]", "{", "}", "(", ")", "<", ">",
        "?", "!", "@", "#", "$", "%", "^", "\\",
    ].map(KeyboardBarKey.symbol)

    private init() {
        let codes = UserDefaults.standard.stringArray(forKey: Self.defaultsKey)
            ?? Self.defaultCodes
        entries = codes.compactMap(KeyboardBarKey.init(code:)).map(Entry.init(key:))
    }

    /// Puts the arrangement on a terminal, if it changed. The bar is a
    /// software-keyboard fixture: a Mac has nothing to hang it on, and the
    /// library defines none there, so this is the one place that knows.
    func apply(to terminal: TerminalViewState) {
        #if !targetEnvironment(macCatalyst)
            let items = entries.map(\.key.accessoryItem)
            if terminal.inputAccessoryItems != items {
                terminal.inputAccessoryItems = items
            }
        #endif
    }

    /// Catalog keys not currently on the bar. Dividers and free-form custom
    /// keys are not listed — they are added through their own controls and
    /// simply disappear when removed.
    var availableKeys: [KeyboardBarKey] {
        let enabled = Set(entries.map(\.key))
        return Self.catalog.filter { !enabled.contains($0) }
    }

    var isDefaultArrangement: Bool {
        entries.map(\.key.code) == Self.defaultCodes
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func add(_ key: KeyboardBarKey) {
        guard key == .divider || !entries.contains(where: { $0.key == key }) else { return }
        entries.append(Entry(key: key))
        persist()
    }

    func reset() {
        entries = Self.defaultCodes
            .compactMap(KeyboardBarKey.init(code:))
            .map(Entry.init(key:))
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(entries.map(\.key.code), forKey: Self.defaultsKey)
    }
}
