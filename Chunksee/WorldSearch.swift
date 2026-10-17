import CoreGraphics
import Foundation
import ChunkseeKit

/// One dimension's part of the world index: what search, the sidebar and the map show.
nonisolated struct DimensionIndex: Sendable {
    var containers: [ItemContainer] = []
    /// Totals of the items in `containers`, most first.
    var storage: [StoredItem] = []
    var signs: [Sign] = []
    var structures: [StructureMarker] = []
    var places: [PlaceMarker] = []
    var creatures: [CreatureMarker] = []
    var biomeAreas: [BiomeArea] = []
    /// Each chunk's surface biome and any cave biomes under it, for the hover readout.
    var biomes: [ChunkCoordinate: String] = [:]
    var caveBiomes: [ChunkCoordinate: [String]] = [:]
    /// Notable blocks per chunk, for `block:` search, richest first.
    var blocks: [ChunkDeposit] = []
    /// Readable and pre-1.18 chunks across the dimension.
    var formats = ChunkFormats()

    /// Reads a dimension from its regions, through the reader's cached parts.
    @concurrent
    static func read(_ reader: RegionReader) async -> DimensionIndex {
        var part = DimensionIndex()
        var spawners: [Spawner] = []
        for region in await reader.everyRegion({ await $0.contents($1) }) {
            guard !Task.isCancelled else { return part }
            part.containers += region.value.containers
            part.signs += region.value.signs
            spawners += region.value.spawners
        }
        guard !Task.isCancelled else { return part }
        part.storage = StoredItem.totals(in: part.containers)
        async let structures = StructureScanner.scan(reader)
        async let places = PlaceScanner.scan(reader.dimension, cache: reader.cache)
        async let creatures = CreatureScanner.scan(reader)
        async let biomes = BiomeScanner.scan(reader)
        async let blocks = reader.everyRegion { await $0.blocks($1) }
        async let formats = reader.everyRegion { await $0.formats($1) }
        part.formats = await formats.reduce(ChunkFormats()) { $0 + $1.value }
        part.structures = await structures
        part.places = await places + spawners.map(PlaceMarker.init)
        part.creatures = await creatures
        let biomeScan = await biomes
        part.biomeAreas = biomeScan.areas
        part.biomes = biomeScan.biomes
        part.caveBiomes = biomeScan.caveBiomes
        part.blocks = await blocks.flatMap { region in
            region.value.flatMap { chunk, deposits in deposits.map { ChunkDeposit(chunk: chunk, deposit: $0) } }
        }.sorted { $0.deposit.count > $1.deposit.count }
        return part
    }
}

/// Everything in the world that search, the sidebar and the map show, by dimension.
nonisolated struct SearchIndex: Sendable {
    struct Placed<Value: Sendable>: Sendable {
        var dimension: String
        var value: Value
    }

    /// Each dimension's part, by dimension id.
    var dimensions: [String: DimensionIndex] = [:]

    /// One kind of thing from every dimension, each with its dimension.
    func all<Value: Sendable>(_ part: KeyPath<DimensionIndex, [Value]>) -> [Placed<Value>] {
        dimensions.flatMap { id, index in index[keyPath: part].map { Placed(dimension: id, value: $0) } }
    }

    var containers: [Placed<ItemContainer>] { all(\.containers) }
    var signs: [Placed<Sign>] { all(\.signs) }
    var structures: [Placed<StructureMarker>] { all(\.structures) }
    var places: [Placed<PlaceMarker>] { all(\.places) }
    var creatures: [Placed<CreatureMarker>] { all(\.creatures) }
    var biomeAreas: [Placed<BiomeArea>] { all(\.biomeAreas) }
}

/// A search that looks at one sidebar layer instead of items and text: `structure:village`,
/// `pet:`, `biome:pale garden`, or villagers' trades with `trade:mending`. On its own, a filter
/// lists everything of its kind.
nonisolated enum LayerFilter: String, CaseIterable, Sendable {
    case structure, place, creature, pet, villager, trade, biome, block

    /// What the filter finds, for search suggestions.
    var prompt: String {
        switch self {
        case .structure: String(localized: "structure: villages, strongholds…")
        case .place: String(localized: "place: portals, beds, bells…")
        case .creature: String(localized: "creature: named creatures, pets, villagers")
        case .pet: String(localized: "pet: tamed creatures")
        case .villager: String(localized: "villager: villagers and traders")
        case .trade: String(localized: "trade: villagers selling or buying an item")
        case .biome: String(localized: "biome: areas of a biome")
        case .block: String(localized: "block: ores and spawners")
        }
    }

    var symbol: String {
        switch self {
        case .structure: StructureGroup.village.symbol
        case .place: PlaceGroup.portal.symbol
        case .creature: CreatureGroup.named.symbol
        case .pet: CreatureGroup.pet.symbol
        case .villager: CreatureGroup.villager.symbol
        case .trade: "arrow.left.arrow.right"
        case .biome: "leaf"
        case .block: "cube"
        }
    }

    /// The filter a query starts with, and the rest of the query.
    static func parse(_ query: String) -> (filter: LayerFilter, rest: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":"),
              let filter = LayerFilter(rawValue: trimmed[..<colon].lowercased()) else { return nil }
        return (filter, String(trimmed[trimmed.index(after: colon)...]))
    }
}

/// One place where matches were found: a container, a sign, a named creature, or a player's
/// inventory or ender chest.
nonisolated struct SearchHit: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case container(kind: String)
        case sign
        /// A marker from a sidebar layer, by its kind.
        case layer(Layer)
        /// A chunk's deposit of a notable block (ore, spawner…).
        case block(NotableBlock)
        case inventory(UUID)
        case enderChest(UUID)
    }

    enum Layer: Equatable, Sendable {
        case structure(StructureGroup)
        case place(PlaceGroup)
        case creature(CreatureGroup)
        case biome(BiomeGroup)
    }

    var id: String
    var source: Source
    var dimension: String?
    /// World X/Z, when the place is on a map (a player's ender chest isn't).
    var position: CGPoint?
    var y: Int?
    /// "Chest", "“Valuables” Barrel", "fahlman’s ender chest", "Sign", "Pale Garden".
    var title: String
    /// "64 Diamond, 3 Diamond Sword", a sign's lines, or a biome area's size.
    var detail: String
    /// Total matching items, for sorting; 1 for a sign, the chunk count for a biome area.
    var count: Int
}

/// Builds the search index and answers searches against it: item names, custom names, book
/// titles, authors and pages, sign text, and creatures' names; or, with a `LayerFilter`, one
/// sidebar layer's markers.
nonisolated enum WorldSearch {
    /// All scans and sorting for a query run on the concurrent executor, using one snapshot.
    @concurrent
    static func execute(_ request: SearchRequest) async -> [String: [SearchHit]] {
        var results: [String: [SearchHit]] = [:]
        for query in request.queries {
            guard !Task.isCancelled else { return [:] }
            results[query] = search(query, in: request.index, players: request.players) {
                request.playerNames[$0.uuid] ?? PlayerPresentation.label(of: $0, singleplayerUUID: nil)
            }
        }
        return results
    }

    static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// One layer's markers matching every word (all of them with no words): biome areas largest
    /// first, everything else by id.
    static func search(_ filter: LayerFilter, words: [String], in index: SearchIndex) -> [SearchHit] {
        let hits: [SearchHit]
        switch filter {
        case .structure: hits = layerHits(index.structures, words: words, y: \.y) { .structure($0.group) }
        case .place: hits = layerHits(index.places, words: words, y: { $0.y }) { .place($0.group) }
        case .creature: hits = layerHits(index.creatures, words: words, y: { Coordinates.block($0.creature.y) }) { .creature($0.group) }
        case .pet: hits = layerHits(index.creatures.filter { $0.value.group == .pet }, words: words,
                                   y: { Coordinates.block($0.creature.y) }) { .creature($0.group) }
        case .villager: hits = layerHits(index.creatures.filter { $0.value.group == .villager }, words: words,
                                        y: { Coordinates.block($0.creature.y) }) { .creature($0.group) }
        case .trade: hits = tradeHits(index.creatures, words: words)
        case .block: hits = blockHits(index, words: words)
        case .biome:
            // An area is named by its size, so its biome leads the row.
            hits = layerHits(index.biomeAreas, words: words, count: \.chunkCount) { .biome($0.group) }
                .map { var hit = $0; swap(&hit.title, &hit.detail); return hit }
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// At most this many `block:` results. Common ores are in hundreds of thousands of chunks
    /// (diamond ore alone in about 150,000 in Ryan's Realm); listing and pinning them all made
    /// searching take seconds and would slow every redraw of the map.
    static let blockResultLimit = 1000

    /// The richest chunks holding a notable block whose name or id matches every word, one hit per
    /// chunk and block. The pin sits at the chunk's center; the detail gives the height range to dig.
    private static func blockHits(_ index: SearchIndex, words: [String]) -> [SearchHit] {
        let blocks = Set(NotableBlock.allCases.filter { contains($0.searchText, words: words) })
        guard !blocks.isEmpty else { return [] }
        // Each dimension's deposits are already richest first, so its first matches are its best.
        var best: [(dimension: String, deposit: ChunkDeposit)] = []
        for (dimension, part) in index.dimensions {
            best += part.blocks.lazy.filter { blocks.contains($0.deposit.block) }.prefix(blockResultLimit).map { (dimension, $0) }
        }
        best.sort { $0.deposit.deposit.count > $1.deposit.deposit.count }
        return best.prefix(blockResultLimit).map { dimension, entry in
            let chunk = entry.chunk, deposit = entry.deposit
            return SearchHit(id: "\(dimension)@\(deposit.block.rawValue)@\(chunk.x),\(chunk.z)", source: .block(deposit.block),
                             dimension: dimension, position: CGPoint(x: chunk.x * 16 + 8, y: chunk.z * 16 + 8), y: deposit.minY,
                             title: deposit.block.name,
                             // One line: the row's second line already gives the chunk's X and Z. Hundreds of
                             // wrapping rows appearing at once crashed the sidebar's layout (fahlman/Chunksee#81).
                             detail: String(localized: "\(deposit.count) blocks · Y \(deposit.minY) to \(deposit.maxY)"),
                             count: deposit.count)
        }
    }

    /// Villagers and traders with a trade matching every word (in an item's name or id, or an
    /// enchantment's name), one hit per villager listing those trades, most matching trades first.
    private static func tradeHits(_ entries: [SearchIndex.Placed<CreatureMarker>], words: [String]) -> [SearchHit] {
        entries.compactMap { entry in
            guard let villager = entry.value.creature.villager else { return nil }
            let matching = villager.trades.filter { contains(TradeText.searchText(of: $0), words: words) }
            guard !matching.isEmpty else { return nil }
            let job = villager.profession.flatMap { $0 == "minecraft:none" ? nil : ReadableName.from($0) } ?? entry.value.name
            let title = villager.level.map { "\(job), \(TradeText.levelName($0))" } ?? job
            let detail = matching.map { trade in
                let offer = String(localized: "\(TradeText.describe(trade.sell)) for \(TradeText.cost(of: trade))")
                return trade.isSoldOut ? String(localized: "\(offer) (sold out)") : offer
            }.joined(separator: "; ")
            return SearchHit(id: "\(entry.dimension)@\(entry.value.id)#trades", source: .layer(.creature(entry.value.group)),
                             dimension: entry.dimension, position: entry.value.position, y: Coordinates.block(entry.value.creature.y),
                             title: title, detail: detail, count: matching.count)
        }
    }

    /// Markers whose search text contains every word, as hits: the marker's name leads and its kind follows.
    private static func layerHits<Marker: MapLayerMarker & Sendable>(_ entries: [SearchIndex.Placed<Marker>], words: [String],
                                                                     count: (Marker) -> Int = { _ in 1 },
                                                                     y: (Marker) -> Int? = { _ in nil },
                                                                     layer: (Marker) -> SearchHit.Layer) -> [SearchHit] {
        entries.filter { !Task.isCancelled && contains($0.value.searchText, words: words) }.map { entry in
            SearchHit(id: "\(entry.dimension)@\(entry.value.id)", source: .layer(layer(entry.value)), dimension: entry.dimension,
                      position: entry.value.position, y: y(entry.value), title: entry.value.group.name, detail: entry.value.name,
                      count: count(entry.value))
        }
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
                       name: (PlayerInfo) -> PlayerPresentation.Name) -> [SearchHit] {
        if let (filter, rest) = LayerFilter.parse(query) {
            return search(filter, words: words(in: rest), in: index)
        }
        let words = words(in: query)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for player in players {
            guard !Task.isCancelled else { return [] }
            let who = name(player)
            let location = PlayerPresentation.position(of: player)
            if let found = summary(of: player.inventory + player.equipment.values, words: words) {
                hits.append(SearchHit(id: "inventory-\(player.uuid)", source: .inventory(player.uuid), dimension: location?.dimension,
                                      position: location.map { CGPoint(x: $0.x, y: $0.z) }, y: location.flatMap { Coordinates.block($0.y) },
                                      title: who.inventory, detail: found.text, count: found.count))
            }
            if let found = summary(of: player.enderChest, words: words) {
                hits.append(SearchHit(id: "ender-\(player.uuid)", source: .enderChest(player.uuid), dimension: nil, position: nil, y: nil,
                                      title: who.enderChest, detail: found.text, count: found.count))
            }
        }
        for entry in index.containers {
            guard !Task.isCancelled else { return [] }
            let container = entry.value
            guard let found = summary(of: container.items, words: words) else { continue }
            let kind = ReadableName.from(container.kind)
            let title = container.customName.map { "“\($0)” \(kind)" } ?? kind
            hits.append(SearchHit(id: "\(entry.dimension)@\(container.kind)@\(container.x),\(container.y),\(container.z)",
                                  source: .container(kind: container.kind), dimension: entry.dimension,
                                  position: MapCoordinates.center(of: CGPoint(x: container.x, y: container.z)), y: container.y,
                                  title: title, detail: found.text, count: found.count))
        }
        for entry in index.signs {
            guard !Task.isCancelled else { return [] }
            let sign = entry.value
            // Lines are matched together so a phrase can run across them, as signs are written.
            let lines = (sign.front + sign.back).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard contains(lines.joined(separator: " "), words: words) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(sign.kind)@\(sign.x),\(sign.y),\(sign.z)", source: .sign,
                                  dimension: entry.dimension, position: MapCoordinates.center(of: CGPoint(x: sign.x, y: sign.z)),
                                  y: sign.y, title: ReadableName.from(sign.kind), detail: lines.joined(separator: " / "), count: 1))
        }
        // Named creatures by name; `creature:` and `pet:` find the rest.
        for entry in index.creatures {
            guard !Task.isCancelled else { return [] }
            let creature = entry.value.creature
            guard let name = creature.customName, contains(name + " " + ReadableName.from(creature.id), words: words) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(entry.value.id)", source: .layer(.creature(entry.value.group)),
                                  dimension: entry.dimension, position: entry.value.position, y: Coordinates.block(creature.y),
                                  title: ReadableName.from(creature.id), detail: "“\(name)”", count: 1))
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
