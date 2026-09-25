import Foundation

/// The `send` vocabulary: tmux's `send-keys` names, so muscle memory from
/// that tool carries over.
///
/// Cursor and editing keys are sent in their normal (non-application) form.
/// A program that has switched the terminal to DECCKM — vim, less — still
/// reads these: the two forms differ only in the byte after the escape, and
/// both are accepted by every readline and curses binding in practice.
enum KeyNames {
    static let vocabulary = """
    Enter Return Tab Escape Esc Space BSpace Backspace Delete DC IC Insert \
    Up Down Right Left Home End PgUp PgDn F1-F12 C-<key> M-<key>
    """

    /// Bytes for one key name, `nil` when the name is not one.
    static func bytes(for name: String) -> [UInt8]? {
        if let plain = plainBytes(for: name) {
            return plain
        }
        // Each Meta prefix is one ESC ahead of the key, peeled in a loop:
        // the name comes off the CLI's argv, and a run of `M-`s long enough
        // to fit under ARG_MAX once took a stack frame per prefix — and
        // re-lowercased the rest of the name at each — until the process
        // died of it.
        var rest = Substring(name)
        var escapes = 0
        while rest.count > 2, rest.hasPrefix("M-") || rest.hasPrefix("m-") {
            rest = rest.dropFirst(2)
            escapes += 1
        }
        guard escapes > 0 else { return nil }
        let key = String(rest)
        return [UInt8](repeating: 0x1B, count: escapes) + (plainBytes(for: key) ?? Array(key.utf8))
    }

    /// A name with no Meta prefix: a named key, or a `C-` combination.
    private static func plainBytes(for name: String) -> [UInt8]? {
        if let simple = simpleKeys[name.lowercased()] {
            return Array(simple.utf8)
        }
        if name.count > 2, name.hasPrefix("C-") || name.hasPrefix("c-") {
            return controlBytes(for: String(name.dropFirst(2)))
        }
        return nil
    }

    /// `C-c` is 0x03: the control form of a letter is its low five bits.
    /// The handful of non-letters readline users reach for are spelled out.
    private static func controlBytes(for key: String) -> [UInt8]? {
        if key.count == 1, let scalar = key.unicodeScalars.first {
            let value = scalar.value
            if value >= 97, value <= 122 {
                return [UInt8(value - 96)]
            } // a-z
            if value >= 65, value <= 90 {
                return [UInt8(value - 64)]
            } // A-Z
            switch scalar {
            case "@", " ": return [0x00]
            case "[": return [0x1B]
            case "\\": return [0x1C]
            case "]": return [0x1D]
            case "^": return [0x1E]
            case "_": return [0x1F]
            case "?": return [0x7F]
            default: return nil
            }
        }
        return nil
    }

    private static let simpleKeys: [String: String] = {
        var keys: [String: String] = [
            "enter": "\r",
            "return": "\r",
            "tab": "\t",
            "escape": "\u{1B}",
            "esc": "\u{1B}",
            "space": " ",
            "bspace": "\u{7F}",
            "backspace": "\u{7F}",
            "delete": "\u{1B}[3~",
            "dc": "\u{1B}[3~",
            "insert": "\u{1B}[2~",
            "ic": "\u{1B}[2~",
            "up": "\u{1B}[A",
            "down": "\u{1B}[B",
            "right": "\u{1B}[C",
            "left": "\u{1B}[D",
            "home": "\u{1B}[H",
            "end": "\u{1B}[F",
            "pgup": "\u{1B}[5~",
            "pageup": "\u{1B}[5~",
            "pgdn": "\u{1B}[6~",
            "pagedown": "\u{1B}[6~",
        ]
        // F1-F4 are SS3-introduced, F5 and up are CSI with a number; this is
        // xterm's layout, which is what `xterm-ghostty` describes.
        let functionKeys = [
            "\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS",
            "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~", "\u{1B}[19~",
            "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~",
        ]
        for (index, sequence) in functionKeys.enumerated() {
            keys["f\(index + 1)"] = sequence
        }
        return keys
    }()
}
