//
//  TerminalDirectory.swift
//  iGhostVT
//

import Foundation

/// A directory a session sits in, in the two spellings the product needs.
///
/// They differ wherever the directory belongs to the bootstrap, which sits
/// somewhere nobody would recognise: a randomly named jbroot under
/// roothide, `/var/jb` under rootless. The kernel calls a shell's directory
/// `/var/containers/Bundle/Application/<uuid>/usr/src` and only that is a
/// path the daemon can `chdir` to, so one spelling is carried to be handed
/// back and the other — `@jb/usr/src` — to be read. The daemon sends the
/// second only when it says something
/// (`iGhostVTWireKey.displayDirectory`).
struct TerminalDirectory: Hashable, Codable, Sendable {
    /// Exactly as the daemon reported it, and the only spelling
    /// `openSession` takes back (`startDirectory`). Never shown.
    var path: String
    /// The same directory as the bootstrap's own programs print it — what
    /// the user typed to get here, and what a menu row says.
    var display: String

    init(path: String, display: String? = nil) {
        self.path = path
        self.display = display.flatMap { $0.isEmpty ? nil : $0 } ?? path
    }

    /// What a row calls this directory. Nothing is abbreviated here: the
    /// daemon already wrote the home against `~` and the rest of the
    /// bootstrap against `@jb`, and it is the only side that can. Under
    /// roothide the session's home is `<jbroot>/var/mobile`, so an app
    /// collapsing `/var/mobile` would miss the real home *and* rename
    /// iOS's own directory of that name — which is what it did.
    var label: String {
        display
    }

    /// Whether this is the session user's home. The new-tab menu's first
    /// row already opens there, so no other row should offer it again, and
    /// the daemon spelling it `~` is the whole test.
    var isHome: Bool {
        display == "~"
    }

    /// A path as a person should read it, for the one reading the daemon
    /// never makes: the shell's own OSC 7, which the Live Activity falls
    /// back to before the session has reported. Some shells send a
    /// `file://` URL and others a bare path.
    ///
    /// Deliberately *not* used on a reported directory — see `label`.
    static func abbreviate(_ reported: String?) -> String {
        guard var path = reported, !path.isEmpty else { return "" }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        return path
    }
}
