import Foundation

/// A window's tabs kept together by the device their shell runs on: this
/// device's first, then each paired device's, by name.
enum TabGrouping {
    /// Off, the tabs are one freely ordered list and the sidebar has no
    /// device headers.
    static let isEnabled = true

    struct Group<Item> {
        /// The paired device's id; nil for this device.
        var hostID: String?
        var items: [Item]

        /// What a collapsed group is remembered by, across launches.
        var key: String {
            hostID.map { "host:" + $0 } ?? "local"
        }
    }

    /// Paired devices' ids in the order their groups take.
    static func hostOrder(_ hosts: [(id: String, name: String)]) -> [String] {
        hosts.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
        .map(\.id)
    }

    /// `items` with each device's items together, in group order: this
    /// device's, then the devices of `hostOrder`, then any device missing
    /// from it, as it first appears. Each device's items keep their order.
    static func arranged<Item>(_ items: [Item], hostID: (Item) -> String?, hostOrder: [String]) -> [Item] {
        var rank: [String: Int] = [:]
        for host in hostOrder where rank[host] == nil {
            rank[host] = rank.count
        }
        for item in items {
            if let host = hostID(item), rank[host] == nil {
                rank[host] = rank.count
            }
        }
        func position(_ item: Item) -> Int {
            hostID(item).map { 1 + rank[$0, default: rank.count] } ?? 0
        }
        return items.enumerated()
            .sorted { (position($0.element), $0.offset) < (position($1.element), $1.offset) }
            .map(\.element)
    }

    /// Each device's items, the devices in the order they first appear —
    /// for `arranged` items, the runs as they stand. One group per device
    /// whatever the order: the keys identify views.
    static func groups<Item>(_ items: [Item], hostID: (Item) -> String?) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        for item in items {
            let host = hostID(item)
            if let index = groups.firstIndex(where: { $0.hostID == host }) {
                groups[index].items.append(item)
            } else {
                groups.append(Group(hostID: host, items: [item]))
            }
        }
        return groups
    }

    /// A reorder never carries a tab into another device's group.
    static func allowsMove(from hostID: String?, to destination: String?) -> Bool {
        !isEnabled || hostID == destination
    }
}
