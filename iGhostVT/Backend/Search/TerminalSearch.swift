//
//  TerminalSearch.swift
//  iGhostVT
//

import Combine
import Foundation
import GhosttyTerminal

@MainActor
final class TerminalSearch: ObservableObject {
    enum Direction {
        case older
        case newer

        fileprivate var bindingAction: String {
            switch self {
            case .older: "navigate_search:next"
            case .newer: "navigate_search:previous"
            }
        }
    }

    @Published private(set) var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var total: Int?
    @Published private(set) var selected: Int?
    @Published private(set) var showsNoResults = false
    @Published private(set) var focusRequest = 0

    var isEditing = false {
        didSet {
            guard oldValue, !isEditing else { return }
            FindHistory.shared.fence()
        }
    }

    let dismissals = PassthroughSubject<Bool, Never>()
    var isAvailable: (@MainActor () -> Bool)?

    var hasMatches: Bool {
        (total ?? 0) > 0
    }

    private static let noResultsDelay: TimeInterval = 0.4
    private static let layoutSettleInterval: TimeInterval = 1.5
    private static let selectionRetryInterval: TimeInterval = 0.3
    private static let selectionPatience: TimeInterval = 5
    private static let maximumQueryLength = 512

    private weak var terminal: TerminalViewState?
    private var pacer = FindQueryPacer()
    private var needle = ""
    private var isSurfaceActive = true
    private var terminalHadFocus = false
    private var delayGeneration = 0
    private var noResultsGeneration = 0

    private var pendingSelection: Direction?
    private var pendingSelectionDeadline: TimeInterval = 0
    private var selectionRequestedAt: TimeInterval = 0
    private var reselectsUntil: TimeInterval = 0
    private var wantsFieldFocus = false

    private var reportedTotal: Int??
    private var reportedSelected: Int??
    private var isFlushScheduled = false

    init(terminal: TerminalViewState) {
        self.terminal = terminal
        terminal.onSearch = { [weak self] event in
            self?.surfaceDidReport(event)
        }
    }

    // MARK: - Presentation

    func present(needle: String? = nil) {
        guard isAvailable?() ?? true else { return }
        if !isPresented {
            terminalHadFocus = terminal?.attachedPlatformView?.isFirstResponder ?? false
            reselectsUntil = Self.now + Self.layoutSettleInterval
            isPresented = true
        }
        if let needle = needle.map(Self.normalized), !needle.isEmpty {
            query = needle
            submit(selecting: .older)
        } else if query.isEmpty, let recent = FindHistory.shared.queries.first {
            query = recent
            submit(selecting: nil)
        } else if self.needle != query {
            submit(selecting: nil)
        }
        requestFieldFocus()
    }

    func takeFieldFocusRequest() -> Bool {
        defer { wantsFieldFocus = false }
        return wantsFieldFocus
    }

    private func requestFieldFocus() {
        wantsFieldFocus = true
        focusRequest += 1
    }

    func dismiss() {
        guard isPresented else { return }
        let returnsFocus = isEditing && Self.terminalTakesFocus(hadFocus: terminalHadFocus)
        isPresented = false
        isEditing = false
        wantsFieldFocus = false
        reselectsUntil = 0
        delayGeneration += 1
        pacer.reset()
        needle = ""
        clearResults()
        _ = terminal?.performBindingAction("end_search")
        dismissals.send(returnsFocus)
    }

    private static func terminalTakesFocus(hadFocus: Bool) -> Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            hadFocus
        #endif
    }

    // MARK: - Query

    func edit(_ text: String) {
        let text = Self.normalized(text)
        guard text != query else { return }
        query = text
        switch pacer.edited(text, at: Self.now) {
        case .search:
            submit(selecting: .older)
        case .wait:
            scheduleDelayedSearch()
        case .idle:
            break
        }
    }

    func search(for text: String) {
        query = Self.normalized(text)
        submit(selecting: .older)
        requestFieldFocus()
    }

    func navigate(_ direction: Direction) {
        guard isPresented else {
            present()
            if isPresented, !needle.isEmpty {
                awaitSelection(direction)
            }
            return
        }
        guard !needle.isEmpty, Self.isSameNeedle(needle, query) else {
            submit(selecting: direction)
            return
        }
        needle = query
        guard isSurfaceActive else { return }
        if hasMatches, terminal?.performBindingAction(direction.bindingAction) == true {
            pendingSelection = nil
            return
        }
        guard total != 0 else { return }
        clearResults()
        awaitSelection(direction)
        startSearch()
    }

    func setSurfaceActive(_ isActive: Bool) {
        guard isActive != isSurfaceActive else { return }
        isSurfaceActive = isActive
        guard isPresented, !needle.isEmpty else { return }
        if isActive {
            startSearch()
        } else {
            clearResults()
            _ = terminal?.performBindingAction("search:")
        }
    }

    private func scheduleDelayedSearch() {
        delayGeneration += 1
        let generation = delayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + FindQueryPacer.delay) { [weak self] in
            guard let self, generation == delayGeneration, isPresented else { return }
            if pacer.delayElapsed(query) == .search {
                submit(selecting: .older)
            }
        }
    }

    private func submit(selecting direction: Direction?) {
        delayGeneration += 1
        pacer.searched(query)
        needle = query
        FindHistory.shared.add(needle)
        guard !needle.isEmpty else {
            clearResults()
            if isSurfaceActive {
                startSearch()
            }
            return
        }
        if let direction {
            awaitSelection(direction)
        } else {
            pendingSelection = nil
        }
        if isSurfaceActive {
            startSearch()
        }
    }

    private func startSearch() {
        _ = terminal?.performBindingAction("search:\(needle)")
    }

    private func clearResults() {
        noResultsGeneration += 1
        pendingSelection = nil
        reportedTotal = nil
        reportedSelected = nil
        if total != nil { total = nil }
        if selected != nil { selected = nil }
        if showsNoResults { showsNoResults = false }
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func normalized(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(printable).prefix(maximumQueryLength))
    }

    private static func isSameNeedle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8) { asciiLowercased($0) == asciiLowercased($1) }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41 ... 0x5A).contains(byte) ? byte + 0x20 : byte
    }

    // MARK: - Selecting the first match

    private func awaitSelection(_ direction: Direction) {
        pendingSelection = direction
        pendingSelectionDeadline = Self.now + Self.selectionPatience
        selectionRequestedAt = 0
    }

    private func requestPendingSelection() {
        guard let direction = pendingSelection, hasMatches, selected == nil else { return }
        let now = Self.now
        guard now <= pendingSelectionDeadline else {
            pendingSelection = nil
            return
        }
        let wait = Self.selectionRetryInterval - (now - selectionRequestedAt)
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.requestPendingSelection()
            }
            return
        }
        selectionRequestedAt = now
        _ = terminal?.performBindingAction(direction.bindingAction)
    }

    // MARK: - What the surface reports

    private func surfaceDidReport(_ event: TerminalSearchEvent) {
        switch event {
        case let .started(needle):
            present(needle: needle)
        case .ended:
            dismiss()
        case let .total(total):
            surfaceDidReport(total: total)
        case let .selected(selected):
            surfaceDidReport(selected: selected)
        }
    }

    private func surfaceDidReport(total: Int?) {
        reportedTotal = .some(total)
        scheduleFlush()
    }

    private func surfaceDidReport(selected: Int?) {
        reportedSelected = .some(selected)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushReports()
        }
    }

    private func flushReports() {
        isFlushScheduled = false
        let newTotal = reportedTotal
        let newSelected = reportedSelected
        reportedTotal = nil
        reportedSelected = nil
        guard isPresented, isSurfaceActive, !needle.isEmpty else { return }
        if let newSelected {
            let hadSelection = selected != nil
            if newSelected != selected {
                selected = newSelected
            }
            if newSelected != nil {
                pendingSelection = nil
            } else if hadSelection, pendingSelection == nil, Self.now < reselectsUntil {
                awaitSelection(.older)
            }
        }
        if let newTotal {
            if newTotal != total {
                total = newTotal
            }
            updateNoResults()
        }
        requestPendingSelection()
    }

    private func updateNoResults() {
        noResultsGeneration += 1
        guard total == 0 else {
            if showsNoResults { showsNoResults = false }
            return
        }
        guard !showsNoResults else { return }
        let generation = noResultsGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noResultsDelay) { [weak self] in
            guard let self, generation == noResultsGeneration, total == 0 else { return }
            showsNoResults = true
        }
    }
}
