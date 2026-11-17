import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeIndex

/// One dimension's part of the world index: what search, the sidebar and the map show.
nonisolated struct DimensionContent: Sendable {
    var containers: [ItemContainer] = []
    /// Totals of the items in `containers`, most first.
    var storage: [StoredItemTotal] = []
    var signs: [Sign] = []
    var structures: [StructureMarker] = []
    var placePoints = PointMarkers<PlaceMarker>()
    private(set) var mobTypes = MobTypes()
    var creaturePoints: PointMarkers<CreatureMarker> { mobTypes.points }
    var places: [PlaceMarker] {
        get { placePoints.all }
        set { placePoints = PointMarkers(newValue) }
    }
    var creatures: [CreatureMarker] {
        get { creaturePoints.all }
        set { mobTypes = MobTypes(newValue) }
    }
    var biomeAreas: [BiomeArea] = []
    /// Each chunk's surface biome and any cave biomes under it, for the hover readout.
    var biomes: [ChunkPosition: String] = [:]
    var caveBiomes: [ChunkPosition: [String]] = [:]
    /// Readable and pre-1.18 chunks across the dimension.
    var formats = ChunkFormats()
    /// Shared retained facts and native projections, replaced only for successfully read regions.
    var shared: ChunkseeIndex.DimensionIndex?
    var regions: [RegionPosition: RegionIndex] = [:]

    /// Reads a dimension from its regions, through the reader's cached library facts.
    @concurrent
    static func read(_ reader: RegionReader, previous: DimensionContent?, change: RegionChange) async -> DimensionContent {
        (try? await reader.world.whileAvailable {
            await readAvailable(reader, previous: previous, change: change)
        }) ?? previous ?? DimensionContent()
    }

    private static func readAvailable(_ reader: RegionReader, previous: DimensionContent?, change: RegionChange) async -> DimensionContent {
        guard let available = reader.availableRegions else { return previous ?? DimensionContent() }
        let previousIndex = previous?.shared ?? ChunkseeIndex.DimensionIndex(
            dimension: reader.dimension.id, caveBiomeIDs: BiomePresentation.caveBiomeIDs)
        let selected = change.mapRegions
        let changed = previousIndex.regionsToRead(available: available, selected: selected)
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
        guard !Task.isCancelled else { return previous ?? DimensionContent() }
        let shared = previousIndex.updating(available: available, selected: selected,
                                           replacements: replacements.values.map(\.index))
        var part = DimensionContent()
        part.shared = shared
        for coordinate in shared.regions.keys {
            part.regions[coordinate] = replacements[coordinate] ?? previous?.regions[coordinate]
        }
        var creatures: [CreatureMarker] = []
        for coordinate in part.regions.keys.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
            let region = part.regions[coordinate]!
            part.structures += region.structures
            creatures += region.creatures
        }
        part.containers = shared.containers
        part.storage = shared.storage
        part.signs = shared.signs
        part.biomes = shared.biomes
        part.caveBiomes = shared.caveBiomes
        part.formats = shared.formats
        part.structures.sort { $0.id < $1.id }
        part.creatures = creatures.sorted { $0.id < $1.id }
        part.places = PlacePresentation.markers(from: shared.pointsOfInterest, portals: shared.portals)
            + shared.spawners.map(PlaceMarker.init) + shared.containers.compactMap { PlaceMarker(unopened: $0) }
        part.biomeAreas = BiomePresentation.areas(from: shared.biomeAreas)
        return part
    }
}

/// Everything in the world that search, the sidebar and the map show, by dimension.
typealias SearchIndex = ChunkseeIndex.WorldIndex<DimensionContent>

extension SearchIndex {
    nonisolated var containers: [Placed<ItemContainer>] { all(\.containers) }
    nonisolated var signs: [Placed<Sign>] { all(\.signs) }
    nonisolated var structures: [Placed<StructureMarker>] { all(\.structures) }
    nonisolated var places: [Placed<PlaceMarker>] { all(\.places) }
    nonisolated var creatures: [Placed<CreatureMarker>] { all(\.creatures) }
    nonisolated var biomeAreas: [Placed<BiomeArea>] { all(\.biomeAreas) }
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
        case .creature: String(localized: "creature: saved mobs")
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
    var dimension: String?
    /// World X/Z, when the place is on a map (a player's ender chest isn't).
    var position: CGPoint?
    var y: Int?
    /// Saved facts needed to describe this result. No language snapshot or formatted label is retained.
    let content: Content
    /// Derived once from immutable facts, so sorting many containers does not recount their items.
    let count: Int

    enum Content: Equatable, Sendable {
        case container(kind: String, customName: String?, items: [ItemMatch])
        case sign(kind: String, lines: [String])
        case structure(StructureMarker)
        case place(PlaceMarker)
        case creature(CreatureMarker)
        case trades(CreatureMarker, matching: [Trade])
        // A result needs the area's identity and size, not its potentially large drawing paths.
        case biome(markerID: String, group: BiomeGroup, chunkCount: Int)
        case block(BlockDeposit)
        case inventory(playerID: UUID, name: GameNames.PlayerName, items: [ItemMatch])
        case enderChest(playerID: UUID, name: GameNames.PlayerName, items: [ItemMatch])
    }

    var source: Source {
        switch content {
        case .container(let kind, _, _): .container(kind: kind)
        case .sign: .sign
        case .structure(let marker): .layer(.structure(marker.group), markerID: marker.id)
        case .place(let marker): .layer(.place(marker.group), markerID: marker.id)
        case .creature(let marker), .trades(let marker, _): .layer(.creature(marker.group), markerID: marker.id)
        case .biome(let id, let group, _): .layer(.biome(group), markerID: id)
        case .block(let deposit): .block(deposit.block)
        case .inventory(let id, _, _): .inventory(id)
        case .enderChest(let id, _, _): .enderChest(id)
        }
    }

    init(id: String, dimension: String?, position: CGPoint?, y: Int?, content: Content) {
        self.id = id
        self.dimension = dimension
        self.position = position
        self.y = y
        self.content = content
        count = switch content {
        case .container(_, _, let items), .inventory(_, _, let items), .enderChest(_, _, let items):
            items.reduce(0) { $0 + $1.count }
        case .trades(_, let trades): trades.count
        case .biome(_, _, let chunks): chunks
        case .block(let deposit): deposit.count
        default: 1
        }
    }

    var items: [ItemMatch] {
        switch content {
        case .container(_, _, let items), .inventory(_, _, let items), .enderChest(_, _, let items): items
        default: []
        }
    }

    func title(in names: GameNames) -> String { names.searchTitle(self) }
    func detail(in names: GameNames) -> String { names.searchDetail(self) }

    struct ItemMatch: Equatable, Sendable {
        let name: GameNames.ItemName
        let count: Int
        var id: String { name.id }
        func text(in names: GameNames) -> String { names.searchItem(self) }
    }
}

/// One query publication preserves full totals when its rows were limited before display.
nonisolated enum SearchMatches: Sendable {
    case all([SearchHit])
    /// The library has already ranked and limited these rows within one dimension.
    case nearest([SearchHit], total: Int, dimension: String)

    var hits: [SearchHit] {
        switch self {
        case .all(let hits), .nearest(let hits, _, _): hits
        }
    }
}

/// Builds the search index and answers searches against it: item names, custom names, book
/// titles, authors and pages, sign text, and creatures' names; or, with a `LayerFilter`, one
/// sidebar layer's markers.
nonisolated enum WorldSearch {
    /// All scans and sorting for a query run on the concurrent executor, using one snapshot.
    @concurrent
    static func execute(_ request: SearchRequest) async -> WorldQueryStore.Results {
        var results: WorldQueryStore.Results = [:]
        for text in request.queries {
            guard !Task.isCancelled else { return [:] }
            let query = SearchQuery(text)
            if query.filter == .block {
                results[text] = blockMatches(request.blocks, query: query, gameNames: request.gameNames)
            } else {
                results[text] = .all(search(text, in: request.index, players: request.players, gameNames: request.gameNames) {
                    request.playerNames[$0.uuid] ?? GameNames.PlayerName(playerID: $0.uuid, singleplayerUUID: nil, knownName: nil)
                })
            }
        }
        return results
    }

    /// One layer's markers matching every word (all of them with no words): biome areas largest
    /// first, everything else by id.
    static func search(_ filter: LayerFilter, query: SearchQuery, in index: SearchIndex, gameNames: GameNames,
                       blocks: BlockQueryInput? = nil) -> [SearchHit] {
        let hits: [SearchHit]
        switch filter {
        case .structure: hits = layerHits(index.structures, query: query, gameNames: gameNames, y: \.y, content: SearchHit.Content.structure)
        case .place: hits = layerHits(index.places, query: query, gameNames: gameNames, y: { $0.y }, content: SearchHit.Content.place)
        case .creature, .pet, .villager: hits = creatureHits(index.creatures, filter: filter, query: query, gameNames: gameNames)
        case .trade: hits = tradeHits(index.creatures, query: query, gameNames: gameNames)
        case .block: return blockMatches(blocks, query: query, gameNames: gameNames).hits
        case .biome:
            hits = layerHits(index.biomeAreas, query: query, gameNames: gameNames) {
                .biome(markerID: $0.id, group: $0.group, chunkCount: $0.chunkCount)
            }
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// Rank the running window's dimension before applying the sidebar/map's row limit.
    /// The pin sits at the chunk's center; the detail gives the height range to dig.
    private static func blockMatches(_ input: BlockQueryInput?, query: SearchQuery, gameNames: GameNames) -> SearchMatches {
        guard let input, let index = input.counts.dimensions[input.point.dimension] else { return .all([]) }
        let groups = Set(input.catalog.groups.filter { query.matches($0.searchText(in: input.catalog, gameNames: gameNames)) })
        let matches: BlockCountIndex.DepositMatches
        do {
            matches = try index.matchingDeposits(matching: groups, using: input.catalog, from: input.point.origin,
                                                limit: SearchModel.rowLimit)
        } catch {
            // Like other search scans, cancellation returns no hits; the query owner rejects
            // the cancelled task before it can replace a retained publication.
            return .all([])
        }
        let hits = matches.nearest.map { entry in
            let dimension = input.point.dimension, chunk = entry.chunk, deposit = entry.deposit
            return SearchHit(id: "\(dimension)@\(deposit.block.id)@\(chunk.x),\(chunk.z)",
                             dimension: dimension, position: chunk.blockOrigin.map { CGPoint(x: $0.x + 8, y: $0.z + 8) }, y: deposit.minY,
                             content: .block(deposit))
        }
        return .nearest(hits, total: matches.totalCount, dimension: input.point.dimension)
    }

    /// Villagers and traders with a trade matching every word (in an item's name or id, or an
    /// enchantment's name), one hit per villager listing those trades, most matching trades first.
    private static func tradeHits(_ entries: [SearchIndex.Placed<CreatureMarker>], query: SearchQuery, gameNames: GameNames) -> [SearchHit] {
        entries.compactMap { entry in
            guard LayerFilter.trade.includes(entry.value.group), let villager = entry.value.creature.villager else { return nil }
            let matching = villager.trades.filter { query.matches(gameNames.tradeSearchText(of: $0)) }
            guard !matching.isEmpty else { return nil }
            return SearchHit(id: "\(entry.dimension)@\(entry.value.id)#trades",
                             dimension: entry.dimension, position: entry.value.position, y: Coordinates.block(entry.value.creature.y),
                             content: .trades(entry.value, matching: matching))
        }
    }

    private static func creatureHits(_ entries: [SearchIndex.Placed<CreatureMarker>], filter: LayerFilter,
                                     query: SearchQuery, gameNames: GameNames) -> [SearchHit] {
        layerHits(entries, query: query, gameNames: gameNames, including: { filter.includes($0.group) },
                  y: { Coordinates.block($0.creature.y) }, content: SearchHit.Content.creature)
    }

    /// Markers whose search text contains every word, as hits: the marker's name leads and its kind follows.
    private static func layerHits<Marker: MapLayerMarker & Sendable>(_ entries: [SearchIndex.Placed<Marker>], query: SearchQuery,
                                                                     gameNames: GameNames,
                                                                     including: (Marker) -> Bool = { _ in true },
                                                                     y: (Marker) -> Int? = { _ in nil },
                                                                     content: (Marker) -> SearchHit.Content) -> [SearchHit] {
        entries.filter { !Task.isCancelled && including($0.value) && query.matches($0.value.searchText(in: gameNames)) }.map { entry in
            layerHit(entry, y: y(entry.value), content: content(entry.value))
        }
    }

    /// Filtered layers and plain named-creature search share marker identity and coordinate construction.
    private static func layerHit<Marker: MapLayerMarker & Sendable>(_ entry: SearchIndex.Placed<Marker>,
                                                                  y: Int?, content: SearchHit.Content) -> SearchHit {
        SearchHit(id: "\(entry.dimension)@\(entry.value.id)", dimension: entry.dimension,
                  position: entry.value.position, y: y, content: content)
    }

    /// Whether an item matches every word in its readable name, id, custom name or book text.
    static func matches(_ item: ItemStack, query: SearchQuery, gameNames: GameNames) -> Bool {
        var labels = GameNames.ItemLabels(gameNames)
        return matches(item, query: query, labels: &labels)
    }

    private static func matches(_ item: ItemStack, query: SearchQuery, labels: inout GameNames.ItemLabels) -> Bool {
        var text = [labels.label(of: item), item.id]
        if let book = item.book { text.append(book.searchText) }
        return query.matches(text.joined(separator: "\n"))
    }

    private struct ItemLabel: Hashable, Sendable {
        let name: GameNames.ItemName
        let text: String
        var id: String { name.id }

        init(_ item: ItemStack, labels: inout GameNames.ItemLabels) {
            name = GameNames.ItemName(item)
            text = labels.label(name)
        }

        // Preserve same-ID, same-visible-label grouping, even when distinct raw names produce
        // that label. Keep one representative's typed inputs; this temporary key never escapes.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.text == rhs.text }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(text) }
    }

    struct ItemSummary: Equatable, Sendable {
        let items: [SearchHit.ItemMatch]
        var count: Int { items.reduce(0) { $0 + $1.count } }
        func text(in names: GameNames) -> String { names.searchItems(items) }
    }

    /// Matching item facts, with nested contents included and the existing quantity/name order.
    static func summary(of items: [ItemStack], query: SearchQuery, gameNames: GameNames) -> ItemSummary? {
        var labels = GameNames.ItemLabels(gameNames)
        return summary(of: items, query: query, labels: &labels)
    }

    private static func summary(of items: [ItemStack], query: SearchQuery, labels: inout GameNames.ItemLabels) -> ItemSummary? {
        let totals = ItemTotals(in: items, matching: { matches($0, query: query, labels: &labels) },
                               groupingBy: { ItemLabel($0, labels: &labels) })
        guard !totals.isEmpty else { return nil }
        let matches = totals.quantities.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return GameNames.namePrecedes($0.key.text, id: $0.key.id, $1.key.text, id: $1.key.id)
        }.map { SearchHit.ItemMatch(name: $0.key.name, count: $0.value) }
        return ItemSummary(items: matches)
    }

    /// Places matching the query text, most items first. `name(of:)` names players.
    static func search(_ text: String, in index: SearchIndex, players: [PlayerInfo], gameNames: GameNames,
                       blocks: BlockQueryInput? = nil,
                       name: (PlayerInfo) -> GameNames.PlayerName) -> [SearchHit] {
        let query = SearchQuery(text)
        if let filter = query.filter {
            return search(filter, query: query, in: index, gameNames: gameNames, blocks: blocks)
        }
        guard !query.isEmpty else { return [] }
        var labels = GameNames.ItemLabels(gameNames)
        var hits: [SearchHit] = []
        for player in players {
            guard !Task.isCancelled else { return [] }
            let who = name(player)
            let location = PlayerPresentation.position(of: player)
            if let found = summary(of: player.searchableInventory, query: query, labels: &labels) {
                hits.append(SearchHit(id: "inventory-\(player.uuid)", dimension: location?.dimension,
                                      position: location.map { CGPoint(x: $0.x, y: $0.z) }, y: location.flatMap { Coordinates.block($0.y) },
                                      content: .inventory(playerID: player.uuid, name: who, items: found.items)))
            }
            if let found = summary(of: player.enderChest, query: query, labels: &labels) {
                hits.append(SearchHit(id: "ender-\(player.uuid)", dimension: nil, position: nil, y: nil,
                                      content: .enderChest(playerID: player.uuid, name: who, items: found.items)))
            }
        }
        for entry in index.containers {
            guard !Task.isCancelled else { return [] }
            let container = entry.value
            guard let found = summary(of: container.items, query: query, labels: &labels) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(container.kind)@\(container.x),\(container.y),\(container.z)",
                                  dimension: entry.dimension,
                                  position: MapCoordinates.center(of: CGPoint(x: container.x, y: container.z)), y: container.y,
                                  content: .container(kind: container.kind, customName: container.customName, items: found.items)))
        }
        for entry in index.signs {
            guard !Task.isCancelled else { return [] }
            let sign = entry.value
            // Matching uses saved spacing; only the displayed caption trims and omits blank lines.
            let savedLines = sign.searchLines
            guard query.matches(savedLines.joined(separator: " ")) else { continue }
            hits.append(SearchHit(id: "\(entry.dimension)@\(sign.kind)@\(sign.x),\(sign.y),\(sign.z)",
                                  dimension: entry.dimension, position: MapCoordinates.center(of: CGPoint(x: sign.x, y: sign.z)),
                                  y: sign.y, content: .sign(kind: sign.kind, lines: savedLines)))
        }
        // Named creatures by name; `creature:` and `pet:` find the rest.
        for entry in index.creatures {
            guard !Task.isCancelled else { return [] }
            let creature = entry.value.creature
            guard creature.customName != nil, query.matches(gameNames.creatureSearchText(creature)) else { continue }
            hits.append(layerHit(entry, y: Coordinates.block(creature.y), content: .creature(entry.value)))
        }
        return hits.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
