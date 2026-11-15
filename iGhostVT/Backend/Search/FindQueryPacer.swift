//
//  FindQueryPacer.swift
//  iGhostVT
//

import Foundation

struct FindQueryPacer {
    enum Step: Equatable {
        case search
        case wait
        case idle
    }

    static let delay: TimeInterval = 0.5
    static let staleAfter: TimeInterval = 3

    private enum State {
        case empty
        case delaying
        case activeShort
        case activeMedium
        case activeLong
    }

    private var state = State.empty
    private var lastEdit: TimeInterval?

    var isDelaying: Bool {
        state == .delaying
    }

    mutating func edited(_ query: String, at time: TimeInterval) -> Step {
        let isStale = lastEdit.map { time - $0 > Self.staleAfter } ?? false
        lastEdit = time
        guard !query.isEmpty else {
            let hadSearch = state != .empty
            state = .empty
            return hadSearch ? .search : .idle
        }
        let length = Self.length(of: query)
        switch state {
        case .empty:
            return length == .short ? startDelay() : activate(length)
        case .delaying:
            return length == .short ? .idle : activate(length)
        case .activeShort, .activeMedium:
            if length == .short, isStale {
                return startDelay()
            }
            if state == .activeMedium, length == .short {
                return .search
            }
            return activate(length)
        case .activeLong:
            return length == .short ? startDelay() : activate(length)
        }
    }

    mutating func delayElapsed(_ query: String) -> Step {
        guard state == .delaying, !query.isEmpty else { return .idle }
        return activate(Self.length(of: query))
    }

    mutating func searched(_ query: String) {
        state = query.isEmpty ? .empty : Self.state(for: Self.length(of: query))
    }

    mutating func reset() {
        state = .empty
        lastEdit = nil
    }

    private enum Length {
        case short
        case medium
        case long
    }

    private static func length(of query: String) -> Length {
        switch query.count {
        case ...2: .short
        case 3 ... 4: .medium
        default: .long
        }
    }

    private static func state(for length: Length) -> State {
        switch length {
        case .short: .activeShort
        case .medium: .activeMedium
        case .long: .activeLong
        }
    }

    private mutating func startDelay() -> Step {
        state = .delaying
        return .wait
    }

    private mutating func activate(_ length: Length) -> Step {
        state = Self.state(for: length)
        return .search
    }
}
