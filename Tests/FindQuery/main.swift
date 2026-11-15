import Foundation

// The find bar's two pieces of pure logic (iGhostVT/Backend/Search): when a
// typed query is searched (FindQueryPacer) and which queries are remembered
// (FindHistoryList).

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

typealias Step = FindQueryPacer.Step

func steps(_ edits: [(String, TimeInterval)]) -> [Step] {
    var pacer = FindQueryPacer()
    return edits.map { pacer.edited($0.0, at: $0.1) }
}

print("pacer: short queries wait, longer ones search")
check(steps([("a", 0)]) == [.wait], "the first character waits")
check(steps([("a", 0), ("ab", 0.1)]) == [.wait, .idle], "a second character keeps the same wait")
check(steps([("a", 0), ("ab", 0.1), ("abc", 0.2)]) == [.wait, .idle, .search], "the third character searches at once")
check(steps([("abc", 0)]) == [.search], "a pasted medium query searches at once")
check(steps([("abcdef", 0)]) == [.search], "a pasted long query searches at once")
check(steps([("", 0)]) == [.idle], "an empty field with nothing searched does nothing")

print("pacer: after the wait")
do {
    var pacer = FindQueryPacer()
    _ = pacer.edited("a", at: 0)
    check(pacer.isDelaying, "a waiting pacer says so")
    check(pacer.delayElapsed("ab") == .search, "the wait ends in a search of what is typed by then")
    check(!pacer.isDelaying, "and the pacer is no longer waiting")
    check(pacer.edited("a", at: 1) == .search, "a short edit right after searches at once")
    check(pacer.edited("ab", at: 5) == .wait, "a short edit after three idle seconds waits again")
}
do {
    var pacer = FindQueryPacer()
    _ = pacer.edited("a", at: 0)
    _ = pacer.edited("", at: 0.1)
    check(pacer.delayElapsed("") == .idle, "a wait whose query was erased searches nothing")
}
do {
    var pacer = FindQueryPacer()
    _ = pacer.edited("a", at: 0)
    _ = pacer.edited("abc", at: 0.1)
    check(pacer.delayElapsed("abc") == .idle, "a wait overtaken by a longer query does not search twice")
}

print("pacer: erasing")
check(
    steps([("abc", 0), ("ab", 0.1), ("a", 0.2), ("", 0.3)]) == [.search, .search, .search, .search],
    "backspacing a medium query searches each step, the empty one included",
)
check(
    steps([("abc", 0), ("", 0.1), ("a", 0.2)]) == [.search, .search, .wait],
    "a field emptied and typed in again waits again",
)
check(
    steps([("abcdef", 0), ("x", 0.1)]) == [.search, .wait],
    "a long query replaced by one character waits",
)
check(
    steps([("abcdef", 0), ("x", 0.1), ("", 0.2)]) == [.search, .wait, .search],
    "erasing during that wait clears the long query's search",
)
check(
    steps([("abcdef", 0), ("abcd", 0.1), ("abcdef", 0.2)]) == [.search, .search, .search],
    "long to medium and back searches every time",
)

print("pacer: a search made elsewhere")
do {
    var pacer = FindQueryPacer()
    pacer.searched("ab")
    check(pacer.edited("a", at: 0) == .search, "after Return on a short query the next short edit searches")
    pacer.searched("")
    check(pacer.edited("a", at: 0.1) == .wait, "after a cleared search the next short edit waits")
    pacer.reset()
    check(pacer.edited("", at: 0.2) == .idle, "a reset pacer has nothing to clear")
}

print("history: what is remembered")
do {
    var history = FindHistoryList()
    history.add("ab")
    check(history.queries.isEmpty, "a query under three characters is not kept")
    history.add("abc")
    history.add("abcd")
    history.add("abcde")
    check(history.queries == ["abcde"], "a query typed out keeps only its longest form")
    history.add("abcd")
    check(history.queries == ["abcde"], "backspacing over it adds nothing")
    history.add("xyz")
    check(history.queries == ["xyz", "abcde"], "a different query goes in front")
    history.add("abcde")
    check(history.queries == ["abcde", "xyz"], "a repeated query moves to the front")
}
do {
    var history = FindHistoryList()
    history.add("abc")
    history.fence()
    history.add("abcd")
    check(history.queries == ["abcd", "abc"], "after a fence a longer query is one of its own")
    history.add("a")
    history.add("abcde")
    check(history.queries == ["abcde", "abcd", "abc"], "a short query is a fence too")
}
do {
    var history = FindHistoryList()
    for index in 0 ..< 14 {
        history.fence()
        history.add("query-\(index)")
    }
    check(history.queries.count == FindHistoryList.capacity, "the list holds its capacity and no more")
    check(history.queries.first == "query-13", "the newest stays in front")
    check(!history.queries.contains("query-3"), "the oldest are dropped")
    history.removeAll()
    check(history.queries.isEmpty, "clearing empties it")
    check(FindHistoryList(Array(repeating: "x", count: 30)).queries.count == FindHistoryList.capacity, "a stored list over capacity is cut on load")
}

if failures.isEmpty {
    print("find-query: all passed")
} else {
    print("find-query: \(failures.count) failed")
    exit(1)
}
