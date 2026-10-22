import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeIndex

/// One dimension's part of the world index: what search, the sidebar and the map show.
nonisolated struct DimensionIndex: Sendable {
    var containers: [ItemContainer] = []
    /// Totals of the items in `containers`, most first.
    var storage: [StoredItem] = []
    var signs: [Sign] = []
    var structures: [StructureMarker] = []
    var placePoints = PointMarkers<PlaceMarker>()
    var creaturePoints = PointMarkers<CreatureMarker>()
    var places: [PlaceMarker] {
        get { placePoints.all }
        set { placePoints = PointMarkers(newValue) }
    }
    var creatures: [CreatureMarker] {
        get { creaturePoints.all }
        set { creaturePoints = PointMarkers(newValue) }
    }
    var biomeAreas: [BiomeArea] = []
    /// Each chunk's surface biome and any cave biomes under it, for the hover readout.
    var biomes: [ChunkPosition: String] = [:]
    var caveBiomes: [ChunkPosition: [String]] = [:]
    /// Notable blocks per chunk, for `block:` search, richest first.
    var blocks: [ChunkDeposit] = []
    /// Readable and pre-1.18 chunks across the dimension.
    var formats = ChunkFormats()
    /// Inputs are replaced per region; all cross-region aggregates derive from these.
    var regions: [RegionPosition: RegionIndex] = [:]

    /// Reads a dimension from its regions, through the reader's cached library facts.
    @concurrent
    static func read(_ reader: RegionReader, previous: DimensionIndex?, change: RegionChange) async -> DimensionIndex {
        var part = DimensionIndex()
        let available = reader.availableRegions
        let changed: Set<RegionPosition>
        if let previous, case .regions(let selected) = change {
            part.regions = previous.regions
            for removed in selected.subtracting(available) { part.regions[removed] = nil }
            changed = selected.intersection(available)
        } else {
            // A failed region read retains its previous contribution; a deleted region does not.
            part.regions = previous?.regions.filter { available.contains($0.key) } ?? [:]
            changed = available
        }
        let replacements = await withTaskGroup(of: (RegionPosition, RegionIndex?).self) { group in
            for region in changed {
                guard !Task.isCancelled else { break }
                group.addTask {
                    let value = await RegionIndex.read(reader, region: region)
                    return (region, value)
                }
            }
            var values: [RegionPosition: RegionIndex] = [:]
            for await (region, value) in group { if let value { values[region] = value } }
            return values
        }
        guard !Task.isCancelled else { return part }
        part.regions.merge(replacements) { $1 }
        var points: [PointOfInterest] = []
        var spawners: [Spawner] = []
        var creatures: [CreatureMarker] = []
        for coordinate in part.regions.keys.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
            let region = part.regions[coordinate]!
            part.containers += region.contents.containers
            part.signs += region.contents.signs
            spawners += region.contents.spawners
            part.structures += region.structures
            creatures += region.creatures
            part.biomes.merge(region.biomes) { $1 }
            part.caveBiomes.merge(region.caveBiomes) { $1 }
            part.blocks += region.blocks.flatMap { chunk, deposits in deposits.map { ChunkDeposit(chunk: chunk, deposit: $0) } }
            part.formats = part.formats + region.formats
            points += region.pointsOfInterest
        }
        part.storage = StoredItem.totals(in: part.containers)
        part.structures.sort { $0.id < $1.id }
        part.creatures = creatures.sorted { $0.id < $1.id }
        part.places = PlaceScanner.markers(from: points, in: reader.dimension.id) + spawners.map(PlaceMarker.init)
            + part.containers.compactMap { PlaceMarker(unopened: $0) }
        part.biomeAreas = BiomeScanner.areas(surface: part.biomes, caves: part.caveBiomes)
        part.blocks.sort { $0.deposit.count > $1.deposit.count }
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
typealias LayerFilter = SearchQuery.Filter

extension SearchQuery.Filter {
    /// What the filter finds, for search suggestions.
    nonisolated var prompt: String {
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

    nonisolated var symbol: String {
        switch self {
        case .structure: StructureGroup.village.symbol
        case .place: PlaceGroup.portal.symbol
        case .creature: CreatureGroup.named.symbol
        case .pet: CreatureGroup.pet.symbol
        case .villager: CreatureGroup.villager.symbol
        case .trade: "arrow.left.arrow.right"
        case .biome: BiomeGroup.symbol
        case .block: "cube"
        }
    }
}

/// One place where matches were found: a container, a sign, a named creature, or a player's
/// inventory or ender chest.
nonisolated struct SearchHit: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case container(kind: String)
        case sign
        /// The current marker can supply details without parsing a hit's display text or ID.
        case layer(Layer, markerID: String)
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
    /// Ancillary details: matching items, a sign's lines, a kind or a biome area's size.
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

    /// One layer's markers matching every word (all of them with no words): biome areas largest
    /// first, everything else by id.
    static func search(_ filter: LayerFilter, query: SearchQuery, in index: SearchIndex) -> [SearchHit] {
        let hits: [SearchHit]
        switch filter {
        case .structure: hits = layerHits(index.structures, query: query, y: \.y) { .structure($0.group) }
        case .place: hits = layerHits(index.places, query: query, y: { $0.y }) { .place($0.group) }
        case .creature: hits = creatureHits(index.creatures, query: query)
        case .pet: hits = creatureHits(index.creatures.filter { $0.value.group == .pet }, query: query)
        case .villager: hits = creatureHits(index.creatures.filter { $0.value.group == .villager }, query: query)
        case .trade: hits = tradeHits(index.creatures, query: query)
        case .block: hits = blockHits(index, query: query)
        case .biome:
            // An area is named by its size, so its biome leads the row.
            hits = layerHits(index.biomeAreas, query: query, count: \.chunkCount) { .biome($0.group) }
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
    private static func blockHits(_ index: SearchIndex, query: SearchQuery) -> [SearchHit] {
        let blocks = Set(NotableBlock.allCases.filter { query.matches($0.searchText) })
        guard !blocks.isEmpty else { return [] }
        // Each dimension's deposits are already richest first, so its first matches are its best.
        var best: [(dimension: String, deposit: ChunkDeposit)] = []
        for (dimension, part) in index.dimensions {
            best += part.blocks.lazy.filter { blocks.contains($0.deposit.block) }.prefix(blockResultLimit).map { (dimension, $0) }
        }
        best.sort { $0.deposit.deposit.count > $1.deposit.deposit.count }
        return best.prefix(blockResultLimit).compactMap { dimension, entry in
            let chunk = entry.chunk, deposit = entry.deposit
            guard let origin = chunk.blockOrigin else { return nil }
            return SearchHit(id: "\(dimension)@\(deposit.block.rawValue)@\(chunk.x),\(chunk.z)", source: .block(deposit.block),
                             dimension: dimension, position: CGPoint(x: origin.x + 8, y: origin.z + 8), y: deposit.minY,
                             title: deposit.block.name,
                             // The inspector shows quantity and height; the sidebar keeps only the block's name.
                             detail: String(localized: "\(deposit.count) blocks · Y \(deposit.minY) to \(deposit.maxY)"),
                             count: deposit.count)
        }
    }

    /// Villagers and traders with a trade matching every word (in an item's name or id, or an
    /// enchantment's name), one hit per villager listing those trades, most matching trades first.
    private static func tradeHits(_ entries: [SearchIndex.Placed<CreatureMarker>], query: SearchQuery) -> [SearchHit] {
        entries.compactMap { entry in
            guard let villager = entry.value.creature.villager else { return nil }
            let matching = villager.trades.filter { query.matches(TradeText.searchText(of: $0)) }
            guard !matching.isEmpty else { return nil }
            let detail = matching.map(TradeText.offer).joined(separator: "; ")
            return SearchHit(id: "\(entry.dimension)@\(entry.value.id)#trades", source: .layer(.creature(entry.value.group), markerID: entry.value.id),
                             dimension: entry.dimension, position: entry.value.position, y: Coordinates.block(entry.value.creature.y),
                             title: entry.value.name, detail: detail, count: matching.count)
        }
    }

    private static func creatureHits(_ entries: [SearchIndex.Placed<CreatureMarker>], query: SearchQuery) -> [SearchHit] {
        layerHits(entries, query: query, y: { Coordinates.block($0.creature.y) }, caption: creatureCaption) { .creature($0.group) }
    }

    /// The row leads with the same name as the sidebar; its caption identifies the kind without repeating the name.
    private static func creatureCaption(_ marker: CreatureMarker) -> String {
        let kind = ReadableName.from(marker.creature.id)
        return marker.name == kind ? marker.group.name : kind
    }

    /// Markers whose search text contains every word, as hits: the marker's name leads and its kind follows.
    private static func layerHits<Marker: MapLayerMarker & Sendable>(_ entries: [SearchIndex.Placed<Marker>], query: SearchQuery,
                                                                     count: (Marker) -> Int = { _ in 1 },
                                                                     y: (Marker) -> Int? = { _ in nil },
                                                                     caption: (Marker) -> String = { $0.group.name },
                                                                     layer: (Marker) -> SearchHit.Layer) -> [SearchHit] {
        entries.filter { !Task.isCancelled && query.matches($0.value.searchText) }.map { entry in
            layerHit(entry, count: count(entry.value), y: y(entry.value), caption: caption(entry.value), layer: layer(entry.value))
        }
    }

    /// Filtered layers and plain named-creature search share marker identity and coordinate construction.
    private static func layerHit<Marker: MapLayerMarker & Sendable>(_ entry: SearchIndex.Placed<Marker>, count: Int = 1,
                                                                  y: Int?, caption: String, layer: SearchHit.Layer) -> SearchHit {
        SearchHit(id: "\(entry.dimension)@\(entry.value.id)", source: .layer(layer, markerID: entry.value.id), dimension: entry.dimension,
                  position: entry.value.position, y: y, title: entry.value.name, detail: caption, count: count)
    }

    /// Whether an item matches every word in its readable name, id, custom name or book text.
    static func matches(_ item: ItemStack, query: SearchQuery) -> Bool {
        var text = [ItemAppearance.label(of: item), item.id]
        if let book = item.book { text += [book.title ?? "", book.author ?? ""] + book.pages }
        return query.matches(text.joined(separator: "\n"))
    }

    private struct ItemLabel: Hashable {
        var id: String
        var text: String

        init(_ item: ItemStack) {
            id = item.id
            text = ItemAppearance.label(of: item)
        }
    }

    /// Matching items summarized as "64 Diamond, 3 Diamond Sword", with nested contents included.
    static func summary(of items: [ItemStack], query: SearchQuery) -> (text: String, count: Int)? {
        let hits = items.flatMap(\.allItems).filter { matches($0, query: query) }
        guard !hits.isEmpty else { return nil }
        let grouped = Dictionary(grouping: hits, by: ItemLabel.init).mapValues { $0.reduce(0) { $0 + $1.count } }
        let text = grouped.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.key.text != $1.key.text { return $0.key.text < $1.key.text }
            return $0.key.id < $1.key.id
        }.map { ItemAppearance.counted($0.key.text, count: $0.value, includingOne: true) }.joined(separator: ", ")
        return (text, hits.reduce(0) { $0 + $1.count })
    }

    /// Places matching the query text, most items first. `name(of:)` names players.
    static func search(_ text: String, in index: SearchIndex, players: [PlayerInfo],
                       name: (PlayerInfo) -> PlayerPresentation.Name) -> [SearchHit] {
        let query = SearchQuery(text)
        if let filter = query.filter {
            return search(filter, query: query, in: index)
        }
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for player in players {
            guard !Task.isCancelled else { return [] }
            let who = name(player)
            let location = PlayerPresentation.position(of: player)
            if let found = summary(of: player.inventory + player.equipment.values, query: query) {
                hits.append(SearchHit(id: "inventory-\(player.uuid)", source: .inventory(player.uuid), dimension: location?.dimension,
                                      position: location.map { CGPoint(x: $0.x, y: $0.z) }, y: location.flatMap { Coordinates.block($0.y) },
                                      title: who.inventory, detail: found.text, count: found.count))
            }
            if let found = summary(of: player.enderChest, query: query) {
                hits.append(SearchHit(id: "ender-\(player.uuid)", source: .enderChest(player.uuid), dimension: nil, position: nil, y: nil,
                                      title: who.enderChest, detail: found.text, count: found.count))
            }
        }
        for entry in index.containers {
            guard !Task.isCancelled else { return [] }
            let container = entry.value
            guard let found = summary(of: container.items, query: query) else { continue }
            let title = ItemAppearance.label(kind: container.kind, customName: container.customName)
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
            guard query.matches(lines.joined(separator: " ")) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(sign.kind)@\(sign.x),\(sign.y),\(sign.z)", source: .sign,
                                  dimension: entry.dimension, position: MapCoordinates.center(of: CGPoint(x: sign.x, y: sign.z)),
                                  y: sign.y, title: ReadableName.from(sign.kind), detail: lines.joined(separator: " / "), count: 1))
        }
        // Named creatures by name; `creature:` and `pet:` find the rest.
        for entry in index.creatures {
            guard !Task.isCancelled else { return [] }
            let creature = entry.value.creature
            guard let name = creature.customName, query.matches(name + " " + ReadableName.from(creature.id)) else { continue }
            hits.append(layerHit(entry, y: Coordinates.block(creature.y), caption: creatureCaption(entry.value),
                                 layer: .creature(entry.value.group)))
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
