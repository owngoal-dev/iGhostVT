//
//  FindHistory.swift
//  iGhostVT
//

import Combine
import Foundation

struct FindHistoryList: Equatable {
    static let capacity = 10
    static let minimumLength = 3

    private(set) var queries: [String]
    private var canCoalesce = false

    init(_ queries: [String] = []) {
        self.queries = Array(queries.prefix(Self.capacity))
    }

    mutating func add(_ query: String) {
        guard query.count >= Self.minimumLength else {
            fence()
            return
        }
        if canCoalesce, let last = queries.first {
            if query.hasPrefix(last) {
                queries.removeFirst()
            } else if last.hasPrefix(query) {
                return
            }
        }
        queries.removeAll { $0 == query }
        queries.insert(query, at: 0)
        if queries.count > Self.capacity {
            queries.removeLast(queries.count - Self.capacity)
        }
        canCoalesce = true
    }

    mutating func fence() {
        canCoalesce = false
    }

    mutating func removeAll() {
        queries = []
        canCoalesce = false
    }
}

@MainActor
final class FindHistory: ObservableObject {
    static let shared = FindHistory()
    static let defaultsKey = "Find.recentQueries"

    @Published private(set) var queries: [String]
    private var list: FindHistoryList

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        list = FindHistoryList(stored)
        queries = list.queries
    }

    func add(_ query: String) {
        list.add(query)
        publish()
    }

    func fence() {
        list.fence()
    }

    func removeAll() {
        list.removeAll()
        publish()
    }

    private func publish() {
        guard queries != list.queries else { return }
        queries = list.queries
        UserDefaults.standard.set(queries, forKey: Self.defaultsKey)
    }
}
