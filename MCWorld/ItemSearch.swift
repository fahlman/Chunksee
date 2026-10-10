import CoreGraphics
import Foundation
import MCWorldKit

/// Readable names from ids: `minecraft:diamond_sword` → "Diamond Sword". Minecraft's own names
/// live in its language files, which can't be redistributed.
nonisolated enum ReadableName {
    static func from(_ id: String) -> String {
        let base = id.split(separator: ":").last.map(String.init) ?? id
        return base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// A container somewhere in the world, remembered with its dimension for searching.
nonisolated struct IndexedContainer: Sendable {
    var dimension: String
    var container: ItemContainer
}

/// One place where matching items were found: a container, or a player's inventory or ender chest.
nonisolated struct ItemHit: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case container(kind: String)
        case inventory(UUID)
        case enderChest(UUID)
    }

    var id: String
    var source: Source
    var dimension: String?
    /// World X/Z, when the place is on a map (a player's ender chest isn't).
    var position: CGPoint?
    var y: Int?
    /// "Chest", "“Valuables” Barrel", "fahlman’s ender chest".
    var title: String
    /// "64 Diamond, 3 Diamond Sword".
    var detail: String
    /// Total matching items, for sorting.
    var count: Int
}

/// Builds the container index and answers searches against it.
nonisolated enum ItemSearch {
    /// Every container in the given dimensions, read region by region in parallel.
    @concurrent
    static func index(_ dimensions: [MCWorldKit.Dimension]) async -> [IndexedContainer] {
        await withTaskGroup(of: [IndexedContainer].self) { group in
            for dimension in dimensions {
                for region in dimension.regionFiles() {
                    group.addTask {
                        guard !Task.isCancelled else { return [] }
                        let found = (try? dimension.containers(regionX: region.x, regionZ: region.z)) ?? []
                        return found.map { IndexedContainer(dimension: dimension.id, container: $0) }
                    }
                }
            }
            var all: [IndexedContainer] = []
            for await found in group { all += found }
            return all
        }
    }

    /// Whether an item matches every word of the query, in its readable name, id or custom name.
    static func matches(_ item: ItemStack, words: [String]) -> Bool {
        let haystack = (ReadableName.from(item.id) + " " + item.id + " " + (item.customName ?? "")).lowercased()
        return words.allSatisfy(haystack.contains)
    }

    /// Matching items summarized as "64 Diamond, 3 Diamond Sword", with nested contents included.
    static func summary(of items: [ItemStack], words: [String]) -> (text: String, count: Int)? {
        let hits = items.flatMap(\.allItems).filter { matches($0, words: words) }
        guard !hits.isEmpty else { return nil }
        let grouped = Dictionary(grouping: hits) { $0.customName.map { "“\($0)”" } ?? ReadableName.from($0.id) }
            .mapValues { $0.reduce(0) { $0 + $1.count } }
        let text = grouped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return (text, hits.reduce(0) { $0 + $1.count })
    }

    /// Places holding items that match `query`, most items first. `name(of:)` names players.
    static func search(_ query: String, containers: [IndexedContainer], players: [PlayerInfo],
                       name: (PlayerInfo) -> String) -> [ItemHit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [ItemHit] = []
        for player in players {
            let who = name(player)
            if let found = summary(of: player.inventory + player.equipment.values, words: words) {
                hits.append(ItemHit(id: "inventory-\(player.uuid)", source: .inventory(player.uuid), dimension: player.position?.dimension,
                                    position: player.position.map { CGPoint(x: $0.x, y: $0.z) }, y: player.position.map { Int($0.y) },
                                    title: String(localized: "\(who)’s inventory"), detail: found.text, count: found.count))
            }
            if let found = summary(of: player.enderChest, words: words) {
                hits.append(ItemHit(id: "ender-\(player.uuid)", source: .enderChest(player.uuid), dimension: nil, position: nil, y: nil,
                                    title: String(localized: "\(who)’s ender chest"), detail: found.text, count: found.count))
            }
        }
        for entry in containers {
            let container = entry.container
            guard let found = summary(of: container.items, words: words) else { continue }
            let kind = ReadableName.from(container.kind)
            let title = container.customName.map { "“\($0)” \(kind)" } ?? kind
            hits.append(ItemHit(id: "\(entry.dimension)@\(container.kind)@\(container.x),\(container.y),\(container.z)",
                                source: .container(kind: container.kind), dimension: entry.dimension,
                                position: CGPoint(x: Double(container.x) + 0.5, y: Double(container.z) + 0.5), y: container.y,
                                title: title, detail: found.text, count: found.count))
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
