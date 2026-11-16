//
//  InputSourceSwitch.swift
//  iGhostVT
//

import Foundation

/// Control-Space switching the keyboard language from a hardware keyboard,
/// as it does everywhere else on iPhone and iPad, once more than one
/// keyboard language is added (`LockableTerminalView.switchesInputSource`).
/// On by default. Off, Control-Space and Control-Shift-Space reach the
/// program in the terminal as they did before, whatever languages are
/// added — it is NUL there, and Emacs's set-mark, a tmux prefix or an
/// editor's completion key. Settings ▸ Keyboard ▸ Shortcuts flips it; it is
/// read on every press, so the change applies at once. Not on the Mac,
/// where AppKit owns the key.
enum InputSourceSwitch {
    static let key = "Keyboard.controlSpaceSwitchesInputSource"
    static let defaultValue = true

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}
