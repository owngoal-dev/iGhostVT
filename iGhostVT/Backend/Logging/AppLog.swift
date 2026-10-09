//
//  AppLog.swift
//  iGhostVT
//

import Dog
import Foundation
import os

/// The app's log. One call writes a line to two places: Dog's journal on
/// disk — `Dog_<date>_<id>.log` under `journalDirectory`, a new file per
/// launch, the last `journalFileCount` kept — and the unified log
/// (`log stream --process iGhostVT`, subsystem `wiki.qaq.iGhostVT`, one
/// category per `Category`). The file is the one that matters on the
/// device: the unified log's relay drops most of a launch's lines while the
/// device is busy — a post-reboot launch reached the Mac with none of its
/// lifecycle — and the file does not. Settings ▸ Advanced ▸ Logs reads it
/// back (`LogReader`), beside the daemon's own file.
///
/// Writes go through a serial queue so no caller — the main actor, ghostty's
/// IO thread reporting a viewport — waits on the disk; Dog stamps the line
/// when it lands, at most milliseconds later, and the order is kept.
enum AppLog {
    /// Dog's tag. The viewer filters by it, so keep the set small and the
    /// names the same ones the code around them uses.
    enum Category: String, CaseIterable {
        case app
        case session
        case tabs
        case transport
        case drop
        case ghostty
        case zmodem
        case keyboard
    }

    enum Level {
        case verbose
        case info
        case warning
        case error

        fileprivate var dogLevel: Dog.DogLevel {
            switch self {
            case .verbose: .verbose
            case .info: .info
            case .warning: .warning
            case .error: .error
            }
        }

        fileprivate var osLogType: OSLogType {
            switch self {
            case .verbose: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        }
    }

    /// Launches kept on disk. Each is one file; a crash's log is the
    /// previous launch's, which is the whole point of keeping more than one.
    static let journalFileCount = 32

    /// Where the journal lives, whether or not Dog managed to open it: the
    /// viewer lists this folder. On the device, the app's data folder,
    /// `Documents/<bundle id>`, where it can be pulled over usbmuxd beside
    /// the app's other files. The app has no container there, so its home is
    /// mobile's, shared with every other app without one; the bundle id keeps
    /// it out of theirs, and the package's postinst makes the folder — and
    /// `Documents`, which a bootstrap need not have — for mobile. Should that
    /// folder still be out of reach, the home's `Library`, which is mobile's
    /// own: a roothide iPad whose `Documents` was left root's wrote no journal
    /// at all, and the viewer said the log could not be read. On the Mac the
    /// app is unsandboxed and Documents is the user's own folder, so the
    /// journal goes under `~/Library/Logs`, beside the helper's
    /// `ighostvtd.log`, where a Mac keeps logs.
    static let journalDirectory: URL = {
        let fileManager = FileManager.default
        let logs = fileManager
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/iGhostVT/Journal", isDirectory: true)
        #if targetEnvironment(macCatalyst)
            return logs
        #else
            let data = fileManager
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "wiki.qaq.iGhostVT", isDirectory: true)
                .appendingPathComponent("Journal", isDirectory: true)
            if (try? fileManager.createDirectory(at: data, withIntermediateDirectories: true)) != nil {
                return data
            }
            return logs
        #endif
    }()

    /// The file this launch writes; nil until `start()` ran, or when the
    /// folder could not be opened.
    static var currentFile: URL? {
        Dog.shared.currentLogFileLocation
    }

    /// Bytes one launch may journal. Within a launch the file is otherwise
    /// unbounded, and with Detailed Terminal Log on it records every chunk
    /// a program prints, so a shell left flooding (`yes | base64`) fills the
    /// data volume through the app. Before Dog 0.1.2 a failed write raised an
    /// ObjC exception and took the app down; it now drops the line, but a
    /// full disk still breaks every other app, so this one stays bounded.
    /// Past the limit the file gets one closing line and the rest of the
    /// launch reaches the unified log only.
    private static let journalByteLimit = 256 << 20

    /// Bytes journaled so far this launch. Touched only on `queue`, which
    /// is what makes the plain counter safe.
    private nonisolated(unsafe) static var journalBytesWritten = 0

    private static let queue = DispatchQueue(label: "wiki.qaq.iGhostVT.log", qos: .utility)
    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map {
            ($0, Logger(subsystem: "wiki.qaq.iGhostVT", category: $0.rawValue))
        },
    )

    /// Opens this launch's file. Called once, first thing in
    /// `didFinishLaunching`; the lines before it reach only the unified log.
    static func start() {
        Dog.shared.maximumLogCount = journalFileCount
        do {
            try Dog.shared.initialization(writableDir: journalDirectory.deletingLastPathComponent())
        } catch {
            loggers[.app]?.error("journal could not be opened at \(journalDirectory.path, privacy: .public)")
        }
        // Retention is enforced here as well as by `maximumLogCount`: Dog's
        // own sweep runs before this launch's file exists, and before 0.1.2
        // it deleted nothing outside DEBUG. After initialization, so this
        // launch's file is among the newest kept.
        for launch in LogReader.launches().dropFirst(journalFileCount) {
            try? FileManager.default.removeItem(at: launch.url)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        AppLog.info(.app, "iGhostVT \(version) (\(build)) on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static func verbose(_ category: Category, _ message: String) {
        write(.verbose, category, message)
    }

    static func info(_ category: Category, _ message: String) {
        write(.info, category, message)
    }

    static func warning(_ category: Category, _ message: String) {
        write(.warning, category, message)
    }

    static func error(_ category: Category, _ message: String) {
        write(.error, category, message)
    }

    /// Whether verbose lines reach the journal (`DetailedTerminalLog`).
    /// The unified log has them either way; it keeps debug lines in memory
    /// only.
    nonisolated(unsafe) static var writesVerbose = false

    private static func write(_ level: Level, _ category: Category, _ message: String) {
        // Public on purpose: nothing here carries user content beyond
        // session ids, sizes, and paths, and a redacted line is useless for
        // the on-device debugging this exists for.
        loggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)")
        if level == .verbose, !writesVerbose {
            return
        }
        queue.async {
            guard journalBytesWritten <= journalByteLimit else { return }
            // Counted with Dog's framing — the level, the timestamp, a tag
            // line when the tag changes — or a flood of tiny chunks would
            // put the file well past the limit the count had reached.
            journalBytesWritten += message.utf8.count + 64
            if journalBytesWritten > journalByteLimit {
                Dog.shared.join(
                    Category.app.rawValue,
                    "journal capped at \(journalByteLimit >> 20) MiB for this launch; the rest reaches the unified log only",
                    level: .warning,
                )
                return
            }
            Dog.shared.join(category.rawValue, message, level: level.dogLevel)
        }
    }
}
