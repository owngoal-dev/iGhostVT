//
//  RecentDirectoryStore.swift
//  iGhostVT
//

import Foundation
import SwiftUI

/// The directories this app's sessions have been in, so a new tab can open
/// in one of them again once the session that was there is gone.
///
/// Every entry came from the daemon: a session reports where its shell is
/// (event 102) and that report lands here. Nothing is guessed from a
/// shell's own OSC 7, because under roothide that spelling is not a path
/// anything can `chdir` to — see ``TerminalDirectory``.
///
/// Persisted in `UserDefaults`, because it has to survive the sessions it
/// describes; the daemon holds no such list, and the app is the only place
/// the two spellings and the visit counts exist.
@MainActor
final class RecentDirectoryStore: ObservableObject {
    static let shared = RecentDirectoryStore()

    /// How the new-tab menu orders the list. The user's choice, in
    /// Settings ▸ Advanced.
    enum SortOrder: String, CaseIterable, Identifiable {
        /// Where they were last — the default, since the thing just left
        /// is usually the thing wanted again.
        case recent
        /// Where they go most often, which outlives a single afternoon's
        /// detour.
        case frequent

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .recent: String(localized: "Last Visited")
            case .frequent: String(localized: "Most Visited")
            }
        }
    }

    /// One remembered directory, with what the two orders sort on.
    struct Entry: Codable, Hashable, Identifiable {
        var directory: TerminalDirectory
        var lastVisited: Date
        var visitCount: Int

        var id: String {
            directory.path
        }
    }

    /// Everything remembered, unordered — `sorted()` is what a menu shows.
    @Published private(set) var entries: [Entry] = []

    /// Whether the menu offers the list at all, and whether visits are
    /// recorded while it is off. Both: a switch that says the app is not
    /// keeping this should mean it. What is already stored stays, so
    /// turning it back on restores the list; Clear is the other control.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    @Published var sortOrder: SortOrder {
        didSet {
            guard sortOrder != oldValue else { return }
            defaults.set(sortOrder.rawValue, forKey: Self.sortOrderKey)
        }
    }

    /// How many directories are kept. Past this the least recently visited
    /// goes, whichever order the menu is in — a directory nobody has opened
    /// in months is not worth a row however often it was once used.
    private static let limit = 40

    /// How many the menu offers. The rest stay stored and keep their
    /// counts; a menu is not a file browser.
    static let menuRowLimit = 8

    static let enabledKey = "RecentDirectories.enabled"
    static let sortOrderKey = "RecentDirectories.sortOrder"
    static let entriesKey = "RecentDirectories.entries"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means on: the list is the point of the menu, and a fresh
        // install should see it fill.
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        sortOrder = defaults.string(forKey: Self.sortOrderKey)
            .flatMap(SortOrder.init(rawValue:)) ?? .recent
        entries = Self.load(from: defaults)
    }

    /// A session says where its shell is. Called for every report the
    /// daemon sends, so the same directory arrives once per visit — the
    /// transport only emits a change — and the count means what it says.
    func record(_ directory: TerminalDirectory) {
        guard isEnabled, directory.path.hasPrefix("/") else { return }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.directory.path == directory.path }) {
            // The display spelling can move under a fixed path: roothide
            // hands out a new jbroot when the environment is recreated.
            updated[index].directory = directory
            updated[index].lastVisited = Date()
            updated[index].visitCount += 1
        } else {
            updated.append(Entry(directory: directory, lastVisited: Date(), visitCount: 1))
        }
        if updated.count > Self.limit {
            updated.sort { $0.lastVisited > $1.lastVisited }
            updated.removeLast(updated.count - Self.limit)
        }
        entries = updated
        save()
    }

    /// The remembered directories as the menu lists them: in the user's
    /// order, without the ones a live tab is already offering, and without
    /// the home — the menu's first row is that.
    func menuDirectories(excluding excluded: Set<String>) -> [TerminalDirectory] {
        guard isEnabled else { return [] }
        let offered = sorted()
            .map(\.directory)
            // The home has its own row at the top of the menu.
            .filter { !excluded.contains($0.path) && !$0.isHome }
        return Array(offered.prefix(Self.menuRowLimit))
    }

    /// Every entry in the user's order. Ties break on the other measure,
    /// then on the path, so the list never shuffles between two openings of
    /// the same menu.
    func sorted() -> [Entry] {
        entries.sorted { first, second in
            switch sortOrder {
            case .recent:
                if first.lastVisited != second.lastVisited {
                    return first.lastVisited > second.lastVisited
                }
                if first.visitCount != second.visitCount {
                    return first.visitCount > second.visitCount
                }
            case .frequent:
                if first.visitCount != second.visitCount {
                    return first.visitCount > second.visitCount
                }
                if first.lastVisited != second.lastVisited {
                    return first.lastVisited > second.lastVisited
                }
            }
            return first.directory.path < second.directory.path
        }
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: entriesKey),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return Array(stored.prefix(limit))
    }
}
