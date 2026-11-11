import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct UnopenedLootTests {
    private let overworld = "minecraft:overworld"

    private func chest(_ x: Int32, table: String? = nil, filled: Bool = false) -> NBT {
        var fields: [String: NBT] = ["id": .string("minecraft:chest"), "x": .int(x), "y": .int(30), "z": .int(2)]
        if let table { fields["LootTable"] = .string(table) }
        if filled { fields["Items"] = .list([.compound(["id": .string("minecraft:diamond"), "count": .int(3)])]) }
        return .compound(fields)
    }

    private func cart(_ identity: Int32, x: Double = -0.5) -> NBT {
        .compound(["id": .string("minecraft:chest_minecart"), "UUID": .intArray([1, 2, 3, identity]),
                   "Pos": .list([.double(x), .double(30), .double(2)]),
                   "LootTable": .string("minecraft:chests/abandoned_mineshaft")])
    }

    private func write(_ blocks: [NBT], entities: [NBT] = [], in world: URL,
                       dimensionID: String = "minecraft:overworld") throws -> [URL] {
        let folder = world.appendingPathComponent("dimensions/" + dimensionID.replacingOccurrences(of: ":", with: "/"))
        for name in ["region", "entities"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let dimension = try #require(try World(contentsOf: world).dimension(dimensionID))
        var terrain = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var nbt = try #require(terrain.nbt.compound)
        nbt["block_entities"] = .list(blocks)
        terrain.nbt = .compound(nbt)
        let terrainFile = dimension.regionURL(at: .init(x: 0, z: 0))
        let entityFile = dimension.regionURL(.entities, at: .init(x: -1, z: 0))
        try Data(TestWorld.regionFile([terrain])).write(to: terrainFile, options: .atomic)
        let entityChunk = TestWorld.ChunkSpec(x: -1, z: 0, nbt: .compound([
            "DataVersion": .int(5023), "Entities": .list(entities),
        ]))
        try Data(TestWorld.regionFile([entityChunk])).write(to: entityFile, options: .atomic)
        return [terrainFile, entityFile]
    }

    @Test func savedTablesNameLootWithoutInventingItemsOrSurroundings() throws {
        let data = try TestWorld.facts(blockEntities: [
            chest(2, table: "minecraft:chests/simple_dungeon"),
            chest(3, table: "minecraft:chests/buried_treasure"),
            chest(4, table: "minecraft:chests/ancient_city"),
            chest(5, table: "example:chests/simple_dungeon"),
            chest(6, table: "minecraft:chests/desert_pyramid", filled: true),
            chest(7, filled: true), chest(8),
        ])
        let markers = data.containers.compactMap { PlaceMarker(unopened: $0) }
        #expect(markers.map { $0.name(in: .unavailable) } == ["Simple Dungeon Loot", "Buried Treasure Loot", "Ancient City Loot",
                                         "Loot: example:chests/simple_dungeon"])
        #expect(markers.allSatisfy { $0.group == .unopenedLoot && $0.y == 30 })
        let index = SearchIndex.overworld(DimensionContent(placePoints: PointMarkers(markers)))
        let matches = WorldSearch.search("place:example:chests/simple_dungeon", in: index, players: [], gameNames: .unavailable) { _ in .named("") }
        #expect(matches.map { $0.title(in: .unavailable) } == ["Loot: example:chests/simple_dungeon"])
        #expect(matches.first?.y == 30)
    }

    @Test(.timeLimit(.minutes(1)))
    func dimensionsVisibilitySelectionAndRefreshShareTheExistingPlacesPath() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try write([chest(2, table: "minecraft:chests/simple_dungeon")], entities: [cart(4), cart(5)], in: url)
        _ = try write([chest(3, table: "example:nether_treasure")], in: url, dimensionID: "minecraft:the_nether")
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults,
                                       cacheRoot: nil, watchWorld: { _, _ in nil })
        let first = WorldSession(resources: resources, dimensionID: overworld)
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        defer { first.close(); nether.close() }
        resources.refreshDelay = .zero
        await resources.index.waitForIndex()
        let original = try #require(resources.index.index.dimensions[overworld]).places
        #expect(original.count == 3 && Set(original.map(\.id)).count == 3)
        #expect(resources.index.index.dimensions["minecraft:the_nether"]?.places.count == 1)
        #expect(!first.visibility.places.contains(.unopenedLoot))
        #expect(MapContent(session: first).places.isEmpty && MapContent(session: nether).places.isEmpty)
        first.visibility.places.insert(.unopenedLoot)
        #expect(MapContent(session: first).places.count == 3 && MapContent(session: nether).places.isEmpty)

        let moving = try #require(original.first { $0.type == "minecraft:chest_minecart" })
        first.selection.choose(.place(moving.id))
        #expect(first.selection.sidebarSelection == .place(moving.id))
        let size = CGSize(width: 400, height: 300), viewport = MapViewport(center: moving.position, scale: 8)
        let locations = MapContent(session: first).accessibleLocations(viewport: viewport, size: size)
        let location = try #require(locations.first { $0.target == .row(.place(moving.id)) })
        #expect(location.y == 30 && location.position == CGPoint(x: -0.5, y: 2.5))
        let hit = try #require(MapContent(session: first).hit(at: CGPoint(x: 200, y: 150), viewport: viewport, size: size))
        #expect(hit.y == 30 && hit.position == moving.position)

        // Opening a chest removes its loot table; moving a cart preserves its selected identity.
        let changed = try write([chest(2, filled: true)], entities: [cart(4, x: -3.5), cart(5)], in: url)
        resources.worldChanged(changed)
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        let refreshed = try #require(resources.index.index.dimensions[overworld]).places
        #expect(refreshed.count == 2 && refreshed.allSatisfy { $0.group == .unopenedLoot })
        #expect(refreshed.first { $0.id == moving.id }?.position == CGPoint(x: -3.5, y: 2.5))
        #expect(first.selection.sidebarSelection == .place(moving.id))
        first.search.text = "diamond"
        await first.search.waitForSearch()
        #expect(first.search.results.count == 1 && first.search.results.first?.count == 3)
        #expect(resources.index.index.dimensions["minecraft:the_nether"]?.places.count == 1)
        first.close(); nether.close()
        await first.waitUntilClosed(); await nether.waitUntilClosed()
    }
}
