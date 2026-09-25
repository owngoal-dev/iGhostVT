//
//  LogReader.swift
//  iGhostVT
//

import Foundation

/// One entry of a log as the viewer shows it: a line, or a line with the
/// continuation lines that followed it.
struct LogEntry: Identifiable, Hashable {
    enum Level: String, CaseIterable, Hashable {
        case verbose
        case info
        case warning
        case error
        case critical
    }

    let id: Int
    let timestamp: String
    let level: Level
    let category: String
    var message: String
    /// The entry as it is in the file, for Copy.
    var text: String
}

/// Which log the viewer reads.
enum LogSource: Hashable {
    /// The app's own journal (`AppLog`, Dog's files under `Documents/Journal`).
    case app
    /// `ighostvtd` and `ighostvtd-io`, which share one file
    /// (`iGhostVTProtocol.daemonLogPath`) and a rotated predecessor.
    case daemon
}

/// One launch of the app: one journal file, named by Dog for the moment it
/// was opened.
struct LogLaunch: Identifiable, Hashable {
    let url: URL
    let date: Date?

    var id: URL {
        url
    }
}

/// A log as read: the entries, every tag seen before filtering, and where
/// it came from — or why it could not be read.
struct LogDocument {
    var entries: [LogEntry] = []
    var categories: [String] = []
    /// The file's path, shown under the title.
    var location = ""
    /// Set when there is no file to read; `entries` is then empty.
    var unreadable = false
    /// Distinguishes one read from the next for the same source, so the
    /// viewer scrolls to the end on a refresh that changed nothing.
    var readAt = Date()
}

/// Reads the two logs back. Dog's format and `DaemonFileLog`'s are both
/// line-oriented and neither is negotiable here: a line that fits neither
/// shape continues the entry before it (a message with a newline in it, or
/// the fragment at the head of a rotated file).
enum LogReader {
    /// The most of a file the viewer takes, from the end. Dog never rotates
    /// within a launch, and a launch with the keystroke log on writes
    /// plenty; the daemon's file is capped at half a megabyte twice over.
    static let maximumByteCount = 2 << 20

    // MARK: - Launches

    /// Every journal file, newest first.
    static func launches() -> [LogLaunch] {
        let directory = AppLog.journalDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix("Dog_") && $0.hasSuffix(".log") }
            .map { LogLaunch(url: directory.appendingPathComponent($0), date: launchDate(of: $0)) }
            .sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?): x > y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.url.lastPathComponent > b.url.lastPathComponent
                }
            }
    }

    /// `Dog_2026-09-01_22-10-43_ACAF51D1.log` → the date in the name. Dog
    /// formats it in the current locale, so this reads it back the same way.
    private static func launchDate(of name: String) -> Date? {
        let parts = name.dropFirst("Dog_".count).split(separator: "_")
        guard parts.count >= 3 else { return nil }
        return launchFormatter.date(from: "\(parts[0])_\(parts[1])")
    }

    private static let launchFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Removes every journal file but this launch's.
    static func deleteOlderLaunches() {
        let current = AppLog.currentFile?.standardizedFileURL
        for launch in launches() where launch.url.standardizedFileURL != current {
            try? FileManager.default.removeItem(at: launch.url)
        }
    }

    // MARK: - Reading

    /// The log for `source`; for the app, `launch` picks a file (nil is this
    /// launch's).
    static func read(_ source: LogSource, launch: URL? = nil) -> LogDocument {
        // The two sources differ in three facts — where the log says it is,
        // which files hold it, and which format parses it — and in nothing
        // else. A missing app journal leaves `urls` empty, which `tail`
        // reports the same way it reports a file it could not open.
        let location: String
        let urls: [URL]
        let parse: (String) -> [LogEntry]
        switch source {
        case .app:
            let url = launch ?? AppLog.currentFile
            location = url?.path ?? AppLog.journalDirectory.path
            urls = url.map { [$0] } ?? []
            parse = parseJournal
        case .daemon:
            location = iGhostVTProtocol.daemonLogPath
            urls = [iGhostVTProtocol.rotatedDaemonLogPath, iGhostVTProtocol.daemonLogPath]
                .map { URL(fileURLWithPath: $0) }
            parse = parseDaemon
        }
        var document = LogDocument()
        document.location = location
        guard let text = tail(of: urls) else {
            document.unreadable = true
            return document
        }
        document.entries = parse(text)
        document.categories = categories(in: document.entries)
        return document
    }

    /// The whole log as one file, for Share: the journal file itself, or
    /// the daemon's rotated file followed by its current one. Written to
    /// the temporary directory under a name that says what it is.
    static func exportFile(_ source: LogSource, launch: URL? = nil) -> URL? {
        let name: String
        let urls: [URL]
        switch source {
        case .app:
            guard let url = launch ?? AppLog.currentFile else { return nil }
            urls = [url]
            let stamp = url.deletingPathExtension().lastPathComponent.dropFirst("Dog_".count)
            name = "iGhostVT-\(stamp).log"
        case .daemon:
            urls = [iGhostVTProtocol.rotatedDaemonLogPath, iGhostVTProtocol.daemonLogPath]
                .map { URL(fileURLWithPath: $0) }
            name = "ighostvtd.log"
        }
        // Copied a megabyte at a time: the journal is the one file here
        // with no size bound short of the launch's cap, and it is exported
        // whole, so reading it into memory first was the jetsam `tail`
        // avoids, one tap away on the same screen.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let manager = FileManager.default
        guard manager.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination)
        else { return nil }
        defer { try? output.close() }
        var copied = 0
        for url in urls {
            guard let input = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? input.close() }
            while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
                guard (try? output.write(contentsOf: chunk)) != nil else { break }
                copied += chunk.count
            }
        }
        guard copied > 0 else {
            try? manager.removeItem(at: destination)
            return nil
        }
        return destination
    }

    /// The last `maximumByteCount` of the files concatenated in order, as
    /// text; nil when none of them could be read. Only that much is ever
    /// read: the last file first, seeking to where the budget starts, and
    /// an earlier one only for what budget is left. A journal written with
    /// the terminal log on runs to gigabytes within one launch, and reading
    /// it whole to keep its last two megabytes was the app jetsammed instead
    /// of the viewer shown. A cut lands mid-line, so the fragment before the
    /// first newline goes.
    private static func tail(of urls: [URL]) -> String? {
        var data = Data()
        var read = false
        var trimmed = false
        var remaining = maximumByteCount
        for url in urls.reversed() {
            // A budget the newer file spent whole leaves this one unread,
            // which is a cut like any other.
            if remaining == 0 {
                trimmed = true
                break
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            if size > UInt64(remaining) {
                trimmed = true
                try? handle.seek(toOffset: size - UInt64(remaining))
            } else {
                try? handle.seek(toOffset: 0)
            }
            // `readToEnd` answers nil for an empty file, which is a file
            // that was read, so only a throw counts against it.
            let part: Data
            do { part = try handle.readToEnd() ?? Data() } catch { continue }
            read = true
            data.insert(contentsOf: part, at: 0)
            remaining = max(0, remaining - part.count)
        }
        guard read else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if trimmed, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    private static func categories(in entries: [LogEntry]) -> [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    // MARK: - Dog's format

    /// Dog writes a `[tag]` line whenever the tag changes, then one line per
    /// message: `* |level| yyyy-MM-dd_HH-mm-ss| message`.
    static func parseJournal(_ text: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        var tag = "?"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                tag = String(line.dropFirst().dropLast())
                continue
            }
            if let entry = parseJournalLine(line, tag: tag, id: entries.count) {
                entries.append(entry)
            } else {
                append(continuation: line, to: &entries, tag: tag)
            }
        }
        return entries
    }

    private static func parseJournalLine(_ line: Substring, tag: String, id: Int) -> LogEntry? {
        guard line.hasPrefix("* |") else { return nil }
        let afterMarker = line.dropFirst(3)
        guard let levelEnd = afterMarker.firstIndex(of: "|") else { return nil }
        let level = LogEntry.Level(rawValue: String(afterMarker[..<levelEnd])) ?? .info
        let afterLevel = afterMarker[afterMarker.index(after: levelEnd)...].drop(while: { $0 == " " })
        guard let stampEnd = afterLevel.firstIndex(of: "|") else { return nil }
        let stamp = String(afterLevel[..<stampEnd]).replacingOccurrences(of: "_", with: " ")
        let message = afterLevel[afterLevel.index(after: stampEnd)...].drop(while: { $0 == " " })
        return LogEntry(
            id: id,
            timestamp: stamp,
            level: level,
            category: tag,
            message: String(message),
            text: String(line),
        )
    }

    // MARK: - The daemon's format

    /// `DaemonFileLog.log`: `MM-dd HH:mm:ss.SSS [pid process] message`. The
    /// process name is the tag; the daemon's lines carry no level.
    static func parseDaemon(_ text: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                continue
            }
            if let entry = parseDaemonLine(line, id: entries.count) {
                entries.append(entry)
            } else {
                append(continuation: line, to: &entries, tag: "ighostvtd")
            }
        }
        return entries
    }

    private static let daemonStampLength = "MM-dd HH:mm:ss.SSS".count

    private static func parseDaemonLine(_ line: Substring, id: Int) -> LogEntry? {
        guard line.count > daemonStampLength + 2 else { return nil }
        let stampEnd = line.index(line.startIndex, offsetBy: daemonStampLength)
        let stamp = line[..<stampEnd]
        guard stamp.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " || $0 == ":" || $0 == "." }),
              line[stampEnd] == " ", line[line.index(after: stampEnd)] == "[",
              let bracketEnd = line[stampEnd...].firstIndex(of: "]")
        else { return nil }
        let inside = line[line.index(stampEnd, offsetBy: 2) ..< bracketEnd]
        let process = inside.split(separator: " ", maxSplits: 1).last.map(String.init) ?? String(inside)
        let message = line[line.index(after: bracketEnd)...].drop(while: { $0 == " " })
        return LogEntry(
            id: id,
            timestamp: String(stamp),
            level: .info,
            category: process,
            message: String(message),
            text: String(line),
        )
    }

    // MARK: - Continuations

    private static func append(continuation line: Substring, to entries: inout [LogEntry], tag: String) {
        if entries.isEmpty {
            entries.append(LogEntry(
                id: 0,
                timestamp: "",
                level: .info,
                category: tag,
                message: String(line),
                text: String(line),
            ))
        } else {
            entries[entries.count - 1].message += "\n" + line
            entries[entries.count - 1].text += "\n" + line
        }
    }
}
