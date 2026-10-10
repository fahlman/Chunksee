import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import Chunksee

@Suite struct WorldSearchTests {
    func item(_ id: String, _ count: Int32, components: [String: NBT]? = nil) -> NBT {
        var c: [String: NBT] = ["id": .string(id), "count": .int(count)]
        if let components { c["components"] = .compound(components) }
        return .compound(c)
    }

    @Test func readableNamesAndMatching() throws {
        #expect(ReadableName.from("minecraft:diamond_sword") == "Diamond Sword")
        let sword = try #require(ItemStack(item("minecraft:diamond_sword", 1, components: ["minecraft:custom_name": .string("Excalibur")])))
        #expect(WorldSearch.matches(sword, words: ["diamond", "sword"]))
        #expect(WorldSearch.matches(sword, words: ["excal"]))
        #expect(!WorldSearch.matches(sword, words: ["diamond", "pickaxe"]))
    }

    @Test func searchFindsContainersNestedItemsAndPlayers() {
        let shulker = item("minecraft:shulker_box", 1, components: ["minecraft:container": .list([.compound(["slot": .int(0), "item": item("minecraft:diamond", 64)])])])
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(10), "y": .int(64), "z": .int(-5), "Items": .list([item("minecraft:diamond", 3), shulker])]),
            .compound(["id": .string("minecraft:barrel"), "x": .int(0), "y": .int(64), "z": .int(0), "Items": .list([item("minecraft:dirt", 64)])]),
        ])])
        let index = SearchIndex.overworld(DimensionIndex(containers: ItemContainer.containers(inChunk: chunk)))
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(2)]),
            "EnderItems": .list([item("minecraft:diamond", 5)]),
        ]))
        let hits = WorldSearch.search("diamond", in: index, players: [player]) { _ in "fahlman" }
        #expect(hits.map(\.count) == [67, 5])   // chest (3 + 64 in the shulker box), then the ender chest
        #expect(hits[0].title == "Chest" && hits[0].detail == "67 Diamond")
        #expect(hits[0].position == CGPoint(x: 10.5, y: -4.5))
        #expect(hits[1].title == "fahlman’s ender chest" && hits[1].position == nil)
        #expect(WorldSearch.search("  ", in: index, players: [player]) { _ in "" }.isEmpty)
    }

    @Test func signsAndBooksMatchTheirText() throws {
        let side = { (lines: [String]) in NBT.compound(["messages": .list(lines.map(NBT.string))]) }
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:sign"), "x": .int(-2895), "y": .int(68), "z": .int(2245),
                       "front_text": side(["East", "Northeast", "to", "Desert"]), "back_text": side(["Village", "", "", ""])]),
            .compound(["id": .string("minecraft:hanging_sign"), "x": .int(0), "y": .int(70), "z": .int(0), "front_text": side(["Exit", "", "", ""])]),
            .compound(["id": .string("minecraft:lectern"), "x": .int(5), "y": .int(64), "z": .int(5), "Book": item("minecraft:written_book", 1, components: [
                "minecraft:written_book_content": .compound(["title": .compound(["raw": .string("Travels")]), "author": .string("fahlman"),
                                                            "pages": .list([.compound(["raw": .string("We found a desert village today.")])])]),
            ])]),
        ])])
        let index = SearchIndex.overworld(DimensionIndex(containers: ItemContainer.containers(inChunk: chunk),
                                signs: Sign.signs(inChunk: chunk)))
        // A phrase can run across a sign's lines and onto its back.
        let hits = WorldSearch.search("desert village", in: index, players: []) { _ in "" }
        #expect(hits.map(\.title).sorted() == ["Lectern", "Sign"])
        #expect(hits.first { $0.source == .sign }?.detail == "East / Northeast / to / Desert / Village")
        #expect(hits.first { $0.title == "Lectern" }?.detail == "1 “Travels” by fahlman")
        #expect(WorldSearch.search("written book", in: index, players: []) { _ in "" }.map(\.title) == ["Lectern"])
        #expect(WorldSearch.search("exit", in: index, players: []) { _ in "" }.map(\.title) == ["Hanging Sign"])
    }

    @Test func sessionIndexesAndSearchesAWorld() async throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        var root = spec.nbt.compound!
        root["block_entities"] = .list([.compound(["id": .string("minecraft:chest"), "x": .int(3), "y": .int(1), "z": .int(4),
                                                   "Items": .list([item("minecraft:golden_apple", 2)])]),
                                       .compound(["id": .string("minecraft:sign"), "x": .int(8), "y": .int(1), "z": .int(9),
                                                  "front_text": .compound(["messages": .list([.string("Orchard"), .string(""), .string(""), .string("")])])])])
        spec.nbt = .compound(root)
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        // The index is built as the world opens, before anyone searches.
        #expect(session.search.isIndexing)
        await session.search.waitForIndex()
        #expect(!session.search.isIndexing)
        session.search.text = "golden apple"
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.detail) == ["2 Golden Apple"])
        session.show(session.search.results[0])
        #expect(session.search.selectedHitID == session.search.results[0].id)
        #expect(session.map?.viewport.center == CGPoint(x: 3.5, y: 4.5))
        session.search.text = "orchard"
        await session.search.waitForSearch()
        #expect(session.search.results.map(\.detail) == ["Orchard"])
        session.search.text = ""
        #expect(session.search.results.isEmpty)
        #expect(session.mapContent.hits.isEmpty)

        // A saved search keeps its results pinned on the map after the search bar is cleared, and
        // is remembered for every world.
        session.search.text = "orchard"
        await session.search.waitForSearch()
        session.saveSearch()
        session.search.text = ""
        #expect(session.mapContent.hits.map(\.detail) == ["Orchard"])
        let saved = try #require(session.savedSearches.all.first)
        #expect(SavedSearches(defaults: defaults).all == [saved])
        session.savedSearches.setShown(saved.id, false)
        #expect(session.mapContent.hits.isEmpty)
        session.savedSearches.remove(saved.id)
        #expect(SavedSearches(defaults: defaults).all.isEmpty)
    }
}

@Suite struct WorldDetailsTests {
    @Test func ruleNamesAndClock() {
        #expect(WorldDetails.readableRule("minecraft:keep_inventory") == "Keep Inventory")
        #expect(WorldDetails.readableRule("doDaylightCycle") == "Do Daylight Cycle")
        #expect(WorldDetails.clockTime(ofDayTicks: 0) == (6, 0))
        #expect(WorldDetails.clockTime(ofDayTicks: 18_000) == (0, 0))
        #expect(WorldDetails.clockTime(ofDayTicks: 24_000 * 3 + 4_245) == (10, 14))
    }

    @Test func sessionReadsDetailsAndShowsOnlyALimitedBorder() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        func write(_ path: String, _ data: [String: NBT]) throws {
            let url = world.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let root = NBT.compound(["DataVersion": .int(5023), "data": .compound(data)])
            try Data(Compression.deflate(root.serialized(), gzip: true)).write(to: url)
        }
        try write("data/minecraft/game_rules.dat", ["minecraft:keep_inventory": .byte(1)])
        try write("data/minecraft/wandering_trader.dat", ["spawn_delay": .int(20_400), "spawn_chance": .int(75)])
        try write("dimensions/minecraft/overworld/data/minecraft/world_border.dat", ["size": .double(2000), "center_x": .double(100), "center_z": .double(0)])
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.details.gameRules.map(\.name) == ["Keep Inventory"])
        #expect(session.details.wanderingTrader?.spawnDelay == 20_400 && session.details.wanderingTrader?.spawnChance == 75)
        #expect(session.mapContent.border?.size == 2000)
        session.inspector = .world
        #expect(session.inspector == .world)
    }
}

@Suite struct RememberedViewTests {
    @Test func reopensInTheLastDimensionAtTheSamePlace() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        try FileManager.default.createDirectory(at: world.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let first = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        first.map?.viewport = MapViewport(center: CGPoint(x: 100, y: -200), scale: 0.5)
        first.selectedDimensionID = "minecraft:the_nether"   // leaving the Overworld remembers it
        first.map?.viewport = MapViewport(center: CGPoint(x: 7, y: 8), scale: 4)
        first.close()

        let second = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { second.close() }
        #expect(second.selectedDimensionID == "minecraft:the_nether")
        #expect(second.map?.viewport == MapViewport(center: CGPoint(x: 7, y: 8), scale: 4))
        second.selectedDimensionID = "minecraft:overworld"
        #expect(second.map?.viewport == MapViewport(center: CGPoint(x: 100, y: -200), scale: 0.5))
    }
}

@Suite struct LayerSearchTests {
    @Test func filtersParseAndOtherColonsDont() {
        #expect(LayerFilter.parse("Pet: Summer")?.filter == .pet && LayerFilter.parse("Pet: Summer")?.rest == " Summer")
        #expect(LayerFilter.parse("structure:")?.filter == .structure)
        #expect(LayerFilter.parse("note: diamonds") == nil)
        #expect(LayerFilter.parse("diamond") == nil)
    }

    @Test func structuresPlacesAndCreatures() throws {
        func start(_ id: String, _ x: Int32) -> NBT {
            .compound(["id": .string(id), "ChunkX": .int(x), "ChunkZ": .int(0), "Children": .list([])])
        }
        let village = StructureMarker(try #require(StructureStart.starts(inChunk: .compound(["structures": .compound(["starts": .compound([
            "minecraft:village_plains": start("minecraft:village_plains", 2)])])])).first))
        let wolf = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: 1, y: 64, z: 2, customName: "Summer", owner: UUID()), dimension: "minecraft:overworld"))
        let cat = try #require(CreatureMarker(Creature(id: "minecraft:cat", x: 5, y: 64, z: 5, owner: UUID()), dimension: "minecraft:overworld"))
        let villager = try #require(Creature(.compound(["id": .string("minecraft:villager"), "Health": .float(20),
                                                         "Pos": .list([.double(9), .double(64), .double(9)]),
                                                         "VillagerData": .compound(["profession": .string("minecraft:farmer")])])))
        let farmer = try #require(CreatureMarker(villager, dimension: "minecraft:overworld"))
        let bed = PlaceMarker(PointOfInterest(type: "minecraft:home", x: 3, y: 64, z: 3, freeTickets: 1))
        let index = SearchIndex.overworld(DimensionIndex(structures: [village],
                                places: [bed],
                                creatures: [wolf, cat, farmer]))
        func search(_ query: String) -> [SearchHit] { WorldSearch.search(query, in: index, players: []) { _ in "" } }
        #expect(search("structure:village").map(\.detail) == ["Plains Village"])
        #expect(search("structure:village_plains").count == 1)
        #expect(search("structure:village").first?.source == .layer(.structure(.village)))
        #expect(search("place:bed").map(\.detail) == ["Bed"])
        #expect(search("pet:").map(\.detail).sorted() == ["Cat", "Summer"])
        #expect(search("pet:wolf").map(\.detail) == ["Summer"])
        #expect(search("creature:").count == 3)
        #expect(search("villager:").map(\.detail) == ["Farmer"])
        // A plain search still finds named creatures by name.
        #expect(search("summer").map(\.detail) == ["“Summer”"])
    }
}

@Suite struct BiomeSearchTests {
    func index() -> SearchIndex {
        var biomes: [ChunkCoordinate: String] = [:]
        for x in 0..<3 { for z in 0..<2 { biomes[ChunkCoordinate(x: x, z: z)] = "minecraft:pale_garden" } }   // 6 chunks
        for z in 5..<9 { biomes[ChunkCoordinate(x: 0, z: z)] = "minecraft:pale_garden" }                       // 4 chunks
        for z in 5..<9 { biomes[ChunkCoordinate(x: 3, z: z)] = "minecraft:plains" }
        return SearchIndex.overworld(DimensionIndex(biomeAreas: BiomeScanner.areas(from: biomes)))
    }

    @Test func biomePrefixSearchesBiomeAreasLargestFirst() {
        let hits = WorldSearch.search("biome:pale garden", in: index(), players: []) { _ in "" }
        #expect(hits.map(\.count) == [6, 4])
        #expect(hits.allSatisfy { $0.detail == "Pale Garden" && $0.source == .layer(.biome(BiomeGroup(id: "minecraft:pale_garden"))) })
        #expect(hits.first?.title == "6 chunks")
        // The id works too, the prefix ignores case, and other searches don't list biomes.
        #expect(WorldSearch.search("Biome:pale_garden", in: index(), players: []) { _ in "" }.count == 2)
        #expect(WorldSearch.search("biome:plains", in: index(), players: []) { _ in "" }.map(\.detail) == ["Plains"])
        #expect(WorldSearch.search("pale garden", in: index(), players: []) { _ in "" }.isEmpty)
        // A filter on its own lists everything of its kind.
        #expect(WorldSearch.search("biome:", in: index(), players: []) { _ in "" }.count == 3)
    }

    @Test func choosingABiomeResultOutlinesTheBiome() async throws {
        let chunks = (0..<2).flatMap { x in (0..<2).map { z in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } } }
        let world = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "biome:plains"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        #expect(session.visibility.biomes.isEmpty)
        session.show(hit)
        #expect(session.visibility.biomes == [BiomeGroup(id: "minecraft:plains")])
        #expect(session.mapContent.biomeAreas.count == 1)
    }
}

extension SearchIndex {
    /// An index of the Overworld alone.
    static func overworld(_ part: DimensionIndex) -> SearchIndex {
        SearchIndex(dimensions: ["minecraft:overworld": part])
    }
}
