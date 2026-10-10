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

/// Everything searchable in a world's dimensions: containers with their items, and signs.
nonisolated struct SearchIndex: Sendable {
    struct Placed<Value: Sendable>: Sendable {
        var dimension: String
        var value: Value
    }

    var containers: [Placed<ItemContainer>] = []
    var signs: [Placed<Sign>] = []
}

/// One place where matches were found: a container, a sign, or a player's inventory or ender chest.
nonisolated struct SearchHit: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case container(kind: String)
        case sign
        case inventory(UUID)
        case enderChest(UUID)
    }

    var id: String
    var source: Source
    var dimension: String?
    /// World X/Z, when the place is on a map (a player's ender chest isn't).
    var position: CGPoint?
    var y: Int?
    /// "Chest", "“Valuables” Barrel", "fahlman’s ender chest", "Sign".
    var title: String
    /// "64 Diamond, 3 Diamond Sword", or a sign's lines.
    var detail: String
    /// Total matching items, for sorting; 1 for a sign.
    var count: Int
}

/// Builds the search index and answers searches against it: item names, custom names, book
/// titles, authors and pages, and sign text.
nonisolated enum WorldSearch {
    /// Every container and sign in the given dimensions, read region by region in parallel.
    @concurrent
    static func index(_ dimensions: [MCWorldKit.Dimension]) async -> SearchIndex {
        await withTaskGroup(of: SearchIndex.self) { group in
            for dimension in dimensions {
                for region in dimension.regionFiles() {
                    group.addTask {
                        guard !Task.isCancelled,
                              let contents = try? dimension.contents(regionX: region.x, regionZ: region.z) else { return SearchIndex() }
                        return SearchIndex(containers: contents.containers.map { .init(dimension: dimension.id, value: $0) },
                                           signs: contents.signs.map { .init(dimension: dimension.id, value: $0) })
                    }
                }
            }
            var all = SearchIndex()
            for await found in group {
                all.containers += found.containers
                all.signs += found.signs
            }
            return all
        }
    }

    static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether `text` contains every word, ignoring case.
    static func contains(_ text: String, words: [String]) -> Bool {
        let haystack = text.lowercased()
        return words.allSatisfy(haystack.contains)
    }

    /// Whether an item matches every word in its readable name, id, custom name or book text.
    static func matches(_ item: ItemStack, words: [String]) -> Bool {
        var text = [ReadableName.from(item.id), item.id, item.customName ?? ""]
        if let book = item.book { text += [book.title ?? "", book.author ?? ""] + book.pages }
        return contains(text.joined(separator: "\n"), words: words)
    }

    /// How a matching item is listed: its custom name, a written book's title and author, or its
    /// readable name.
    static func label(of item: ItemStack) -> String {
        if let name = item.customName { return "“\(name)”" }
        if let book = item.book, let title = book.title {
            return book.author.map { String(localized: "“\(title)” by \($0)") } ?? "“\(title)”"
        }
        return ReadableName.from(item.id)
    }

    /// Matching items summarized as "64 Diamond, 3 Diamond Sword", with nested contents included.
    static func summary(of items: [ItemStack], words: [String]) -> (text: String, count: Int)? {
        let hits = items.flatMap(\.allItems).filter { matches($0, words: words) }
        guard !hits.isEmpty else { return nil }
        let grouped = Dictionary(grouping: hits, by: label).mapValues { $0.reduce(0) { $0 + $1.count } }
        let text = grouped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return (text, hits.reduce(0) { $0 + $1.count })
    }

    /// Places matching `query`, most items first. `name(of:)` names players.
    static func search(_ query: String, in index: SearchIndex, players: [PlayerInfo],
                       name: (PlayerInfo) -> String) -> [SearchHit] {
        let words = words(in: query)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for player in players {
            let who = name(player)
            if let found = summary(of: player.inventory + player.equipment.values, words: words) {
                hits.append(SearchHit(id: "inventory-\(player.uuid)", source: .inventory(player.uuid), dimension: player.position?.dimension,
                                      position: player.position.map { CGPoint(x: $0.x, y: $0.z) }, y: player.position.map { Int($0.y) },
                                      title: String(localized: "\(who)’s inventory"), detail: found.text, count: found.count))
            }
            if let found = summary(of: player.enderChest, words: words) {
                hits.append(SearchHit(id: "ender-\(player.uuid)", source: .enderChest(player.uuid), dimension: nil, position: nil, y: nil,
                                      title: String(localized: "\(who)’s ender chest"), detail: found.text, count: found.count))
            }
        }
        for entry in index.containers {
            let container = entry.value
            guard let found = summary(of: container.items, words: words) else { continue }
            let kind = ReadableName.from(container.kind)
            let title = container.customName.map { "“\($0)” \(kind)" } ?? kind
            hits.append(SearchHit(id: "\(entry.dimension)@\(container.kind)@\(container.x),\(container.y),\(container.z)",
                                  source: .container(kind: container.kind), dimension: entry.dimension,
                                  position: CGPoint(x: Double(container.x) + 0.5, y: Double(container.z) + 0.5), y: container.y,
                                  title: title, detail: found.text, count: found.count))
        }
        for entry in index.signs {
            let sign = entry.value
            // Lines are matched together so a phrase can run across them, as signs are written.
            let lines = (sign.front + sign.back).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard contains(lines.joined(separator: " "), words: words) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(sign.kind)@\(sign.x),\(sign.y),\(sign.z)", source: .sign,
                                  dimension: entry.dimension, position: CGPoint(x: Double(sign.x) + 0.5, y: Double(sign.z) + 0.5),
                                  y: sign.y, title: ReadableName.from(sign.kind), detail: lines.joined(separator: " / "), count: 1))
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
