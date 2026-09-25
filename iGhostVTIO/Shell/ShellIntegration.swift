import Darwin
import Foundation

/// Loads Ghostty's shell integration into the shell a session starts.
///
/// The integration is what makes a tab title mean anything: it reports the
/// running command over OSC 2 at every prompt, the working directory over
/// OSC 7, and command boundaries over OSC 133 — none of which a stock shell
/// on iOS emits by itself. Ghostty normally injects this from its own exec
/// backend; this app spawns through the daemon instead, so the same
/// injection has to happen here.
///
/// Only the environment side is reimplemented, never the scripts: the .deb
/// ships libghostty-spm's bash and zsh integration under
/// `/usr/share/ighostvt` (`package-deb.sh` copies it out of the app's
/// resource bundle), and this file points the shell at it exactly the way
/// `termio/shell_integration.zig` does upstream. Those scripts are the
/// package's own MIT rewrite — Ghostty's bash and zsh integration is GPLv3
/// and must never be substituted for them, in the bundle or here. The
/// package ships nothing for fish, so the fish branch below is inert unless
/// a user drops their own `fish/vendor_conf.d` into that directory. Every
/// path handed to the shell is spelled in the bootstrap's vocabulary
/// (`RuntimeEnvironment.bootstrapPath`), because it is the bootstrap's `zsh` that
/// has to open it; only the existence checks here resolve to what a syscall
/// wants.
enum ShellIntegration {
    /// Where `package-deb.sh` installs the scripts, in bootstrap spelling.
    private static var resourcesDirectory: String {
        RuntimeEnvironment.bootstrapPath("/usr/share/ighostvt")
    }

    /// Which parts of the integration to turn on.
    ///
    /// `title` is the one this app needs; the rest of upstream's features
    /// either need a `ghostty` binary on `PATH` (`path`, `ssh-*`) or change
    /// the cursor and `sudo`'s environment, which is not this app's business
    /// to do behind the user's back. Working-directory and prompt reporting
    /// are not features — the scripts always send those.
    private static let features = "title"

    /// Adds the integration for `shell` to `environment`, and returns the
    /// extra arguments the shell must be started with (bash needs one).
    ///
    /// Returns nothing at all when the scripts are missing or the shell is
    /// one nobody ships an integration for — the session then runs exactly
    /// as it did before, and the app falls back to guessing a title from
    /// what the user types.
    static func apply(shell: String, to environment: inout [String: String]) -> [String] {
        let resources = resourcesDirectory
        guard directoryExists(resources + "/shell-integration") else { return [] }

        switch shellName(shell) {
        case "zsh":
            // zsh reads its startup files from ZDOTDIR, and the .zshenv the
            // scripts ship restores this value and sources the user's own
            // config before loading the integration.
            let directory = resources + "/shell-integration/zsh"
            guard directoryExists(directory) else { return [] }
            if let existing = environment["ZDOTDIR"] {
                environment["GHOSTTY_ZSH_ZDOTDIR"] = existing
            }
            environment["ZDOTDIR"] = directory

        case "bash":
            // bash only reads $ENV in POSIX mode, so the integration has to
            // start it there and undo it from inside the script.
            let script = resources + "/shell-integration/bash/ghostty.bash"
            guard fileExists(script) else { return [] }
            if let existing = environment["ENV"] {
                environment["GHOSTTY_BASH_ENV"] = existing
            }
            environment["ENV"] = script
            // Upstream passes the startup flags it swallowed along with the
            // "1"; this daemon never passes --norc or --noprofile, so the
            // bare marker is the whole message.
            environment["GHOSTTY_BASH_INJECT"] = "1"
            // POSIX mode moves the history file to ~/.sh_history. The script
            // leaves POSIX mode again, so put history back where an
            // interactive bash keeps it — and tell the script to unexport it
            // again, or every child (a zsh run from that bash) inherits
            // bash's history file as its own.
            if environment["HISTFILE"] == nil, let home = environment["HOME"] {
                environment["HISTFILE"] = home + "/.bash_history"
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            environment["GHOSTTY_RESOURCES_DIR"] = resources
            environment["GHOSTTY_SHELL_FEATURES"] = features
            return ["--posix"]

        case "fish":
            // fish autoloads vendor config from XDG_DATA_DIRS.
            let directory = resources + "/shell-integration"
            let existing = environment["XDG_DATA_DIRS"]
                ?? RuntimeEnvironment.bootstrapPath("/usr/local/share")
                + ":" + RuntimeEnvironment.bootstrapPath("/usr/share")
            environment["XDG_DATA_DIRS"] = directory + ":" + existing

        default:
            // sh, dash, and anything else: no integration exists upstream,
            // and pointing a shell at another shell's rc files breaks it.
            return []
        }

        environment["GHOSTTY_RESOURCES_DIR"] = resources
        environment["GHOSTTY_SHELL_FEATURES"] = features
        return []
    }

    /// The shell a path starts, by name.
    ///
    /// A shell *invoked* as `sh` never gets an integration, whatever the
    /// link points at: bash and zsh both change their startup sequence under
    /// that name — no `.zshenv`, no `$ENV` handshake to build on — and the
    /// scripts are written for the sequence each has under its own name. The
    /// app's shell setting is the way out for a user whose passwd entry says
    /// `/bin/sh`: naming `/bin/zsh` or `/bin/bash` there takes the direct
    /// route, where the whole integration applies.
    private static func shellName(_ shell: String) -> String {
        URL(fileURLWithPath: shell).lastPathComponent
    }

    private static func directoryExists(_ bootstrapPath: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: RuntimeEnvironment.resolve(bootstrapPath),
            isDirectory: &isDirectory,
        )
        return exists && isDirectory.boolValue
    }

    private static func fileExists(_ bootstrapPath: String) -> Bool {
        FileManager.default.fileExists(atPath: RuntimeEnvironment.resolve(bootstrapPath))
    }
}
