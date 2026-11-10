import Foundation

// Device groups (iGhostVT/Backend/Session/TabGrouping.swift): the order a
// window's tabs take, and the moves that keep each device's tabs together.

struct Tab {
    let name: String
    let host: String?
}

var failures: [String] = []

func check<Value: Equatable>(_ actual: Value, _ expected: Value, _ description: String) {
    if actual == expected {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description): \(actual) != \(expected)")
        failures.append(description)
    }
}

func local(_ name: String) -> Tab {
    Tab(name: name, host: nil)
}

func remote(_ name: String, _ host: String) -> Tab {
    Tab(name: name, host: host)
}

func arranged(_ tabs: [Tab], order: [String]) -> [String] {
    TabGrouping.arranged(tabs, hostID: \.host, hostOrder: order).map(\.name)
}

print("tab-grouping: device order")
check(
    TabGrouping.hostOrder([(id: "c", name: "dev10"), (id: "a", name: "dev2"), (id: "b", name: "Studio")]),
    ["a", "c", "b"],
    "names sort as Finder sorts them, numbers by value",
)
check(
    TabGrouping.hostOrder([(id: "y", name: "mini"), (id: "x", name: "mini")]),
    ["x", "y"],
    "two devices of one name keep a fixed order",
)

print("tab-grouping: arranging")
check(arranged([], order: []), [], "no tabs")
check(
    arranged([remote("a1", "A"), local("l1"), remote("b1", "B"), local("l2")], order: ["A", "B"]),
    ["l1", "l2", "a1", "b1"],
    "this device's tabs come first",
)
check(
    arranged([remote("b1", "B"), remote("a1", "A"), remote("b2", "B"), remote("a2", "A")], order: ["A", "B"]),
    ["a1", "a2", "b1", "b2"],
    "each device's tabs sit together and keep their order",
)
check(
    arranged([remote("x1", "X"), remote("a1", "A"), remote("y1", "Y"), remote("x2", "X")], order: ["A"]),
    ["a1", "x1", "x2", "y1"],
    "a device no longer paired follows the paired ones, as it first appears",
)
let settled = [local("l1"), remote("a1", "A"), remote("a2", "A"), remote("b1", "B")]
check(arranged(settled, order: ["A", "B"]), ["l1", "a1", "a2", "b1"], "an arranged list stays as it is")
check(
    arranged(settled + [remote("a3", "A")], order: ["A", "B"]),
    ["l1", "a1", "a2", "a3", "b1"],
    "a tab appended joins the end of its device's group",
)
var beside = settled
beside.insert(remote("a3", "A"), at: 2)
check(
    arranged(beside, order: ["A", "B"]),
    ["l1", "a1", "a3", "a2", "b1"],
    "a tab opened beside the active one stays beside it",
)
check(
    arranged(settled, order: ["B", "A", "B"]),
    ["l1", "b1", "a1", "a2"],
    "a renamed device moves its group, and a repeated id changes nothing",
)

print("tab-grouping: groups")
let groups = TabGrouping.groups(settled, hostID: \.host)
check(groups.map(\.key), ["local", "host:A", "host:B"], "one group per device, keyed for the collapsed list")
check(groups.map { $0.items.map(\.name) }, [["l1"], ["a1", "a2"], ["b1"]], "each group holds its device's tabs in order")
let scattered = TabGrouping.groups([remote("a1", "A"), local("l1"), remote("a2", "A")], hostID: \.host)
check(scattered.map(\.key), ["host:A", "local"], "tabs out of order still make one group per device")
check(scattered.map { $0.items.map(\.name) }, [["a1", "a2"], ["l1"]], "a device's scattered tabs join its group")

print("tab-grouping: moves")
check(TabGrouping.allowsMove(from: "A", to: "A"), true, "a tab moves within its device's group")
check(TabGrouping.allowsMove(from: "A", to: "B"), false, "a tab does not move into another device's group")
check(TabGrouping.allowsMove(from: nil, to: "A"), false, "nor between this device and another")

if failures.isEmpty {
    print("tab-grouping: all passed")
} else {
    print("tab-grouping: \(failures.count) failed")
    exit(1)
}
