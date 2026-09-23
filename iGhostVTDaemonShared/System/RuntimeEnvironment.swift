import Darwin

/// Where the bootstrap is installed, and how a path has to be spelled for
/// whoever is going to read it.
///
/// Three environments ship this daemon and they disagree about what `/` means:
///
/// - **roothide** installs the bootstrap into a randomly named directory (the
///   jbroot) whenever the environment is recreated, so no path may hardcode it —
///   there is no fixed prefix. Its binaries are linked against **libvroot**, a
///   compile-time shim that rewrites their path syscalls so they already treat
///   the jbroot as `/`. Their own paths are therefore written unprefixed, and
///   the untouched iOS filesystem is reachable inside the jbroot at `/rootfs`.
/// - **rootless** installs under a fixed `/var/jb`, and its binaries are built
///   with that prefix compiled in: they speak the same real paths the kernel
///   does. `/var/jb/bin/zsh` is what both `execve` and the bootstrap's own
///   `login` expect, and iOS's own `/usr/bin` is just `/usr/bin`.
/// - **rootful**, and the macOS harness, have no prefix at all.
///
/// The daemon works out which by stripping its own known install directory off
/// its own executable path — no libroothide dependency and no bridging header.
/// `ighostvtd` and `ighostvtd-io` are installed side by side, so the same
/// rule serves both.
///
/// Mixing the vocabularies up is the classic bootstrap-path bug, so each
/// direction has its own function and every call site names the one it means:
///
/// - `bootstrapPath(_:)` — a file the bootstrap installed, as its programs
///   spell it.
/// - `systemPath(_:)` — a file on the untouched iOS filesystem, as those same
///   programs spell it.
/// - `resolve(_:)` — either of those, converted to what a syscall wants.
enum RuntimeEnvironment {
    /// Where both daemon programs are installed, relative to the
    /// bootstrap's root.
    private static let installDirectory = "/usr/libexec"

    /// Rootless bootstraps all agree on this prefix, and their binaries carry
    /// it compiled in — so this literal, not whatever it resolves to, is what
    /// goes back into paths.
    private static let rootlessPrefix = "/var/jb"

    /// The filesystem layout the daemon is running under.
    enum Bootstrap: Equatable {
        /// No prefix: a rootful bootstrap, or the harness on macOS. Every
        /// mapping degrades to identity, matching the stub behaviour
        /// roothide's own API has outside its managed environment.
        case none
        /// A fixed-prefix bootstrap whose programs speak real paths.
        ///
        /// `prefix` is the literal its binaries were built against and is
        /// what goes back into a path; `root` is what that resolves to,
        /// which is not always the same directory — `/var/jb` may be a
        /// symlink to a randomly named one, and the kernel answers with
        /// the real path. Recognising a path *as* the bootstrap's takes
        /// the second.
        case rootless(prefix: String, root: String)
        /// A randomly named jbroot whose programs are vroot-linked.
        case roothide(jbroot: String)

        /// How the bootstrap's own programs spell one of *its* files.
        ///
        /// Unprefixed under roothide — vroot resolves it against the jbroot
        /// itself, and prefixing here would resolve the jbroot twice.
        func bootstrapPath(_ path: String) -> String {
            switch self {
            case .none, .roothide: path
            case let .rootless(prefix, _): prefix + path
            }
        }

        /// How those same programs spell a file on the untouched iOS
        /// filesystem, which roothide bridges back in at `/rootfs`.
        func systemPath(_ path: String) -> String {
            switch self {
            case .none, .rootless: path
            case .roothide: "/rootfs" + path
            }
        }

        /// Convert a path in the bootstrap's vocabulary to the one the kernel
        /// wants. This is roothide's `jbroot()`, and a no-op everywhere else.
        func resolve(_ path: String) -> String {
            switch self {
            case .none, .rootless: path
            case let .roothide(jbroot): path.hasPrefix("/") ? jbroot + path : path
            }
        }

        /// Where this bootstrap sits, as the kernel spells it: what a path
        /// has to start with to be one of its files. `nil` when there is
        /// no bootstrap, where nothing is inside one.
        var root: String? {
            switch self {
            case .none: nil
            case let .rootless(_, root): root
            case let .roothide(jbroot): jbroot
            }
        }

        /// The other direction, for showing a kernel path to a person: a
        /// file inside the bootstrap written against `@jb` rather than the
        /// root it really sits at. Neither root is worth showing — under
        /// roothide it is a random jbroot the vroot-linked shell never
        /// prints, and under rootless it is a prefix nobody types — and
        /// one marker says the same thing in both, which is also what
        /// tells the bootstrap's `/usr/bin` from iOS's.
        ///
        /// `nil` when the path is not the bootstrap's at all
        /// (`/var/mobile` belongs to iOS under every layout), so a caller
        /// can leave the second spelling off the wire where it would say
        /// nothing.
        ///
        /// Not the inverse of `resolve`, and never a path to hand back:
        /// `@jb` is for reading.
        func displaySpelling(of kernelPath: String) -> String? {
            guard let root, kernelPath.hasPrefix(root) else { return nil }
            let rest = kernelPath.dropFirst(root.count)
            if rest.isEmpty {
                return Bootstrap.marker
            }
            // Only at a boundary: `/var/jbsomething` is not in `/var/jb`.
            guard rest.hasPrefix("/") else { return nil }
            return Bootstrap.marker + rest
        }

        /// What a bootstrap path is shown as instead of its root. `@`
        /// cannot begin an absolute path, so a row reading `@jb/usr/src`
        /// can never be mistaken for one.
        static let marker = "@jb"
    }

    static let bootstrap: Bootstrap = detect()

    static func bootstrapPath(_ path: String) -> String {
        bootstrap.bootstrapPath(path)
    }

    static func systemPath(_ path: String) -> String {
        bootstrap.systemPath(path)
    }

    static func resolve(_ path: String) -> String {
        bootstrap.resolve(path)
    }

    static func displaySpelling(of kernelPath: String) -> String? {
        bootstrap.displaySpelling(of: kernelPath)
    }

    /// True when a path in the bootstrap's vocabulary exists and is executable.
    static func isExecutable(_ bootstrapPath: String) -> Bool {
        var metadata = stat()
        let resolved = resolve(bootstrapPath)
        guard stat(resolved, &metadata) == 0 else { return false }
        return metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && access(resolved, X_OK) == 0
    }

    private static func detect() -> Bootstrap {
        guard let executable = currentExecutablePath(),
              let slash = executable.lastIndex(of: "/")
        else { return .none }
        let directory = String(executable[..<slash])
        guard directory.hasSuffix(installDirectory) else { return .none }
        let root = String(directory.dropLast(installDirectory.count))
        guard !root.isEmpty else { return .none }
        // A rootless bootstrap may keep its files in a randomly named directory
        // and hang `/var/jb` off it as a symlink, and `currentExecutablePath`
        // is canonical — so compare canonical against canonical, and keep the
        // literal prefix, which is the one its binaries were built against.
        if canonicalPath(rootlessPrefix) == root {
            // The canonical directory, not the literal: this is the one a
            // path read from the kernel will carry.
            return .rootless(prefix: rootlessPrefix, root: root)
        }
        return .roothide(jbroot: root)
    }

    static func currentExecutablePath() -> String? {
        executablePath(pid: getpid())
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes {
            ighostvtProcPIDPath(pid, $0.baseAddress!, UInt32($0.count))
        }
        guard result > 0 else { return nil }
        return canonicalPath(String(cString: buffer))
    }

    static func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) }
        }
        return result.map { _ in String(cString: buffer) }
    }
}
