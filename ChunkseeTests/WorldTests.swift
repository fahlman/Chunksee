import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeIndex
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct WorldSearchTests {
    func item(_ id: String, _ count: Int32, components: [String: NBT]? = nil) -> NBT {
        var c: [String: NBT] = ["id": .string(id), "count": .int(count)]
        if let components { c["components"] = .compound(components) }
        return .compound(c)
    }

    @Test func readableNamesAndMatching() throws {
        #expect(ReadableName.from("minecraft:diamond_sword") == "Diamond Sword")
        let sword = try #require(ItemStack(item("minecraft:diamond_sword", 1, components: ["minecraft:custom_name": .string("Excalibur")])))
        #expect(WorldSearch.matches(sword, query: SearchQuery("diamond sword"), gameNames: .unavailable))
        #expect(WorldSearch.matches(sword, query: SearchQuery("excal"), gameNames: .unavailable))
        #expect(!WorldSearch.matches(sword, query: SearchQuery("diamond pickaxe"), gameNames: .unavailable))
    }

    @Test func searchFindsContainersNestedItemsAndPlayers() {
        let shulker = item("minecraft:shulker_box", 1, components: ["minecraft:container": .list([.compound(["slot": .int(0), "item": item("minecraft:diamond", 64)])])])
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(10), "y": .int(64), "z": .int(-5), "Items": .list([item("minecraft:diamond", 3), shulker])]),
            .compound(["id": .string("minecraft:barrel"), "x": .int(0), "y": .int(64), "z": .int(0), "Items": .list([item("minecraft:dirt", 64)])]),
        ])])
        let index = SearchIndex.overworld(DimensionContent(containers: ItemContainer.containers(inChunk: chunk)))
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Dimension": .string("minecraft:overworld"), "Pos": .list([.double(1), .double(64), .double(2)]),
            "EnderItems": .list([item("minecraft:diamond", 5)]),
        ]))
        let hits = WorldSearch.search("diamond", in: index, players: [player], gameNames: .unavailable) { _ in .named("fahlman") }
        #expect(hits.map(\.count) == [67, 5])   // chest (3 + 64 in the shulker box), then the ender chest
        #expect(hits[0].title(in: .unavailable) == "Chest" && hits[0].detail(in: .unavailable) == "67 Diamond")
        #expect(hits[0].position == CGPoint(x: 10.5, y: -4.5))
        #expect(hits[1].title(in: .unavailable) == "fahlman’s ender chest" && hits[1].position == nil)
        #expect(WorldSearch.search("  ", in: index, players: [player], gameNames: .unavailable) { _ in .named("") }.isEmpty)
    }

    @Test func itemSummaryKeepsDifferentKindsWithTheSameLabelSeparate() throws {
        let items = [ItemStack(id: "first:diamond", count: 2, customName: "Shared"),
                     ItemStack(id: "second:diamond", count: 3, customName: "Shared"),
                     ItemStack(id: "minecraft:bundle", contents: [
                        ItemStack(id: "first:diamond", count: 4, customName: "Shared"),
                     ])]
        let result = try #require(WorldSearch.summary(of: items, query: SearchQuery("shared"), gameNames: .unavailable))
        #expect(result.text(in: .unavailable) == "6 Diamond “Shared”, 3 Diamond “Shared”")
        #expect(result.count == 9)
        #expect(WorldSearch.summary(of: items, query: SearchQuery("unmatched"), gameNames: .unavailable) == nil)
    }

    @Test func anInventoryWithoutARecognizedDimensionRemainsSearchableWithoutAMapPin() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let unknownID = UUID(), localID = UUID()
        func player(_ uuid: UUID, knownDimension: Bool) -> PlayerInfo {
            let fields: [String: NBT] = [
                "Dimension": knownDimension ? .string("minecraft:overworld") : .int(21), "Pos": .list([.double(-8.7), .double(63.9), .double(4.6)]),
                "Inventory": .list([item("minecraft:diamond", 3)]),
            ]
            return PlayerInfo(uuid: uuid, nbt: .compound(fields))
        }
        let original = try await WorldSnapshot.read(url)
        let snapshot = WorldSnapshot(access: original.access, world: original.world, dimensions: original.dimensions,
                                     dimensionDocuments: original.dimensionDocuments, players: [player(unknownID, knownDimension: false), player(localID, knownDimension: true)], details: original.details)
        let defaults = TestDefaults.make()
        let session = try await WorldSession(snapshot: snapshot, names: PlayerNames(defaults: defaults),
                                   savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        session.search.text = "diamond"
        await session.search.waitForSearch()
        let unknown = try #require(session.search.results.first { $0.source == .inventory(unknownID) })
        let local = try #require(session.search.results.first { $0.source == .inventory(localID) })
        #expect(unknown.position == nil && unknown.dimension == nil && unknown.y == nil && unknown.count == 3)
        #expect(local.position == CGPoint(x: -8.7, y: 4.6) && local.dimension == "minecraft:overworld" && local.y == 63)
        let viewport = session.map?.viewport
        session.selection.choose(.hit(query: session.search.text, id: unknown.id))
        #expect(session.map?.viewport == viewport)
        let visible = MapContent(session: session).accessibleLocations(viewport: MapViewport(center: .zero, scale: 1),
                                                            size: CGSize(width: 400, height: 300))
        #expect(!visible.contains { $0.id == "search-" + unknown.id })
        #expect(visible.contains { $0.id == "search-" + local.id })
        session.close()
        await session.waitUntilClosed()
    }

    @Test func personalInventoryPhrasesChangeWhenAnAccountNamedYouBecomesKnown() async {
        let uuid = UUID()
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in (Data(#"{"name":"You"}"#.utf8), 200) }))
        names.looksUpOnline = true
        let player = PlayerInfo(uuid: uuid, nbt: .compound([
            "Inventory": .list([item("minecraft:diamond", 1)]), "EnderItems": .list([item("minecraft:diamond", 2)]),
        ]))
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: PlayerRoster([player]), names: names, singleplayerUUID: { uuid },
                                 firstDimension: nil, savedSearches: SavedSearches(defaults: defaults), gameNames: { .unavailable })
        search.text = "diamond"
        await search.waitForSearch()
        #expect(Set(search.results.map { $0.title(in: .unavailable) }) == ["Your inventory", "Your ender chest"])
        await names.lookUp([uuid])
        await search.waitForSearch()
        #expect(Set(search.results.map { $0.title(in: .unavailable) }) == ["You’s inventory", "You’s ender chest"])
        await search.closeTestWorld()
    }

    @Test func storageTotalsCountNestedItemsOncePerContainer() {
        let shulker = item("minecraft:shulker_box", 1, components: ["minecraft:container": .list([.compound(["slot": .int(0), "item": item("minecraft:diamond", 64)])])])
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(10), "y": .int(64), "z": .int(-5), "Items": .list([item("minecraft:diamond", 3), shulker])]),
            .compound(["id": .string("minecraft:barrel"), "x": .int(0), "y": .int(64), "z": .int(0), "Items": .list([item("minecraft:diamond", 10), item("minecraft:dirt", 64)])]),
        ])])
        let totals = GameNames.unavailable.storedItems(StoredItemTotal.totals(in: ItemContainer.containers(inChunk: chunk)))
        #expect(totals.map(\.name) == ["Diamond", "Dirt", "Shulker Box"])
        #expect(totals.first == StoredItem(id: "minecraft:diamond", name: "Diamond", count: 77, containers: 2))
        #expect(totals.last?.count == 1 && totals.last?.containers == 1)
    }

    @Test func blockSearchFindsOreByChunkWithItsHeight() async throws {
        // Chunk (1, -1): stone with 5 deepslate diamond ore and 1 spawner in section 0 (Y 0–15).
        let palette = ["minecraft:stone", "minecraft:deepslate_diamond_ore", "minecraft:spawner"]
        let spec = TestWorld.chunk(x: 1, z: -1, palette: palette) { x, y, z in
            if y == 3 && z == 0 && x < 5 { return 1 }
            return (x, y, z) == (8, 8, 8) ? 2 : 0
        }
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let definitions = try WorldDefinitions.read(World(contentsOf: world), assets: nil)
        let facts = try await RegionReader.scan(dimension, region: .init(x: 0, z: -1), options: RegionReader.options(definitions: definitions))
        let deposits = BlockDeposit.grouped(try #require(facts.chunks.first).blockDeposits, using: definitions.notableBlocks)
        #expect(deposits == [BlockDeposit(block: .diamond, count: 5, minY: 0, maxY: 15), BlockDeposit(block: .spawner, count: 1, minY: 0, maxY: 15)])

        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "block:diamond"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        #expect(session.search.results.count == 1)
        #expect(hit.title(in: .unavailable) == "Diamond Ore" && hit.detail(in: .unavailable) == "5 blocks · Y 0 to 15" && hit.count == 5)
        #expect(hit.position == CGPoint(x: 24, y: -8) && hit.source == .block(.diamond))
        session.search.text = "block:spawner"
        await session.search.waitForSearch()
        #expect(session.search.results.map { $0.title(in: .unavailable) } == ["Spawner"])
        session.search.text = "block:ancient debris"
        await session.search.waitForSearch()
        #expect(session.search.results.isEmpty)
    }

    @Test func blockSearchKeepsOnlyTheRichestChunks() {
        // More chunks with diamonds than the limit: only the richest are listed, richest first.
        let deposits = (0..<(WorldSearch.blockResultLimit + 500)).map { i in
            ChunkDeposit(chunk: ChunkPosition(x: i, z: 0), deposit: BlockDeposit(block: .diamond, count: i + 1, minY: -64, maxY: -49))
        }.sorted { $0.deposit.count > $1.deposit.count }
        let index = SearchIndex.overworld(DimensionContent(blocks: deposits))
        let hits = WorldSearch.search("block:diamond", in: index, players: [], gameNames: .unavailable) { _ in .named("") }
        #expect(hits.count == WorldSearch.blockResultLimit)
        #expect(hits.first?.count == WorldSearch.blockResultLimit + 500 && hits.last?.count == 501)
        #expect(WorldSearch.search("block:emerald", in: index, players: [], gameNames: .unavailable) { _ in .named("") }.isEmpty)
    }

    @Test func signsAndBooksMatchTheirText() throws {
        let side = { (lines: [String]) in NBT.compound(["messages": .list(lines.map(NBT.string))]) }
        let chunk = NBT.compound(["block_entities": .list([
            .compound(["id": .string("minecraft:sign"), "x": .int(-2895), "y": .int(68), "z": .int(2245),
                       "front_text": side([" East ", "Northeast", "to", " Desert "]), "back_text": side([" Village ", "  ", "", ""])]),
            .compound(["id": .string("minecraft:hanging_sign"), "x": .int(0), "y": .int(70), "z": .int(0), "front_text": side(["Exit", "", "", ""])]),
            .compound(["id": .string("minecraft:lectern"), "x": .int(5), "y": .int(64), "z": .int(5), "Book": item("minecraft:written_book", 1, components: [
                "minecraft:written_book_content": .compound(["title": .compound(["raw": .string("Travels")]), "author": .string("fahlman"),
                                                            "pages": .list([.compound(["raw": .string("We found a desert village today.")])])]),
            ])]),
        ])])
        let index = SearchIndex.overworld(DimensionContent(containers: ItemContainer.containers(inChunk: chunk),
                                signs: Sign.signs(inChunk: chunk)))
        // Saved text matches across a sign's sides; only its displayed caption trims blank space.
        let hits = WorldSearch.search("desert village", in: index, players: [], gameNames: .unavailable) { _ in .named("") }
        #expect(hits.map { $0.title(in: .unavailable) }.sorted() == ["Lectern", "Sign"])
        #expect(hits.first { $0.source == .sign }?.detail(in: .unavailable) == "East / Northeast / to / Desert / Village")
        #expect(hits.first { $0.title(in: .unavailable) == "Lectern" }?.detail(in: .unavailable) == "1 Written Book “Travels” by fahlman")
        #expect(WorldSearch.search("written book", in: index, players: [], gameNames: .unavailable) { _ in .named("") }.map { $0.title(in: .unavailable) } == ["Lectern"])
        #expect(WorldSearch.search("exit", in: index, players: [], gameNames: .unavailable) { _ in .named("") }.map { $0.title(in: .unavailable) } == ["Hanging Sign"])
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        // The index is built as the world opens, before anyone searches.
        #expect(session.search.isIndexing)
        await session.search.waitForIndex()
        #expect(!session.search.isIndexing)
        #expect(session.resources.gameNames.storedItems(session.presentation.selectedIndex.storage).map(\.name) == ["Golden Apple"])
        session.search.text = "golden apple"
        await session.search.waitForSearch()
        #expect(session.search.results.map { $0.detail(in: .unavailable) } == ["2 Golden Apple"])
        session.selection.choose(.hit(query: session.search.text, id: session.search.results[0].id))
        #expect(session.selection.highlighted == [.searchHit(session.search.results[0].id)])
        #expect(session.map?.viewport.center == CGPoint(x: 3.5, y: 4.5))
        session.search.text = "orchard"
        await session.search.waitForSearch()
        #expect(session.search.results.map { $0.title(in: .unavailable) } == ["Sign"])
        #expect(session.search.results.map { $0.detail(in: .unavailable) } == ["Orchard"])
        session.search.text = ""
        #expect(session.search.results.isEmpty)
        #expect(MapContent(session: session).hits.isEmpty)

        // A saved search keeps its results pinned on the map after the search bar is cleared, and
        // is remembered for every world.
        session.search.text = "orchard"
        await session.search.waitForSearch()
        session.search.saveSearch()
        session.search.text = ""
        #expect(MapContent(session: session).hits.map { $0.title(in: .unavailable) } == ["Sign"])
        #expect(MapContent(session: session).hits.map { $0.detail(in: .unavailable) } == ["Orchard"])
        let saved = try #require(session.savedSearches.all.first)
        #expect(SavedSearches(defaults: defaults).all == [saved])
        session.savedSearches.setShown(saved.id, false)
        #expect(MapContent(session: session).hits.isEmpty)
        session.savedSearches.remove(saved.id)
        #expect(SavedSearches(defaults: defaults).all.isEmpty)
    }
}

@Suite(.isolatedStores) struct WorldDetailsTests {
    @Test func traderStatusUsesSavedRuleIdentityAndTheSharedCurrentLegacyPolicy() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("data/minecraft/game_rules.dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = "minecraft:spawn_wandering_traders", custom = "example:spawn_wandering_traders"
        let cases: [([String: NBT], Bool)] = [
            ([:], false), ([current: .byte(0)], true),
            (["doTraderSpawning": .byte(0)], true),
            ([current: .byte(1), "doTraderSpawning": .byte(0)], false),
            ([current: .int(9), "doTraderSpawning": .byte(0)], false),
            ([custom: .byte(0)], false), ([current: .byte(1), custom: .byte(0)], false),
        ]
        for (rules, off) in cases {
            let root = NBT.compound(["DataVersion": .int(5023), "data": .compound(rules)])
            try Data(Compression.deflate(root.serialized(), gzip: true)).write(to: file)
            let details = WorldDetails.read(try World(contentsOf: url))
            #expect(details.wanderingTradersAreOff == off)
            #expect(Set(details.gameRuleRows.map(\.id)) == Set(rules.keys))
            #expect(details.gameRuleRows.map(\.name) == details.gameRuleRows.map(\.name).sorted())
        }
        // Before separate saved data, the same app presentation reads the legacy string rule.
        try FileManager.default.removeItem(at: file)
        let level = NBT.compound(["Data": .compound([
            "DataVersion": .int(3953), "GameRules": .compound(["doTraderSpawning": .string("false")]),
        ])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: url.appendingPathComponent("level.dat"))
        #expect(WorldDetails.read(try World(contentsOf: url)).wanderingTradersAreOff)
    }

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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.details.gameRuleRows.map(\.name) == ["Keep Inventory"])
        #expect(session.details.wanderingTrader?.spawnDelay == 20_400 && session.details.wanderingTrader?.spawnChance == 75)
        #expect(MapContent(session: session).border?.size == 2000)
        session.selection.inspector = .world
        #expect(session.selection.inspector == .world)
    }
}

@Suite(.isolatedStores) struct RememberedViewTests {
    @Test func reopensEachDocumentAtItsOwnViewAndRemembersTheFrontDimension() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        try FileManager.default.createDirectory(at: world.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let first = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let nether = WorldSession(resources: first.resources, dimensionID: "minecraft:the_nether")
        first.map?.viewport = MapViewport(center: CGPoint(x: 100, y: -200), scale: 0.5)
        first.becameActive()
        nether.map?.viewport = MapViewport(center: CGPoint(x: 7, y: 8), scale: 4)
        nether.becameActive()
        first.close(); nether.close()
        await first.waitUntilClosed(); await nether.waitUntilClosed()

        let second = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let overworld = WorldSession(resources: second.resources, dimensionID: "minecraft:overworld")
        defer { second.close(); overworld.close() }
        #expect(second.selectedDimensionID == "minecraft:the_nether")
        #expect(second.map?.viewport == MapViewport(center: CGPoint(x: 7, y: 8), scale: 4))
        #expect(overworld.selectedDimensionID == "minecraft:overworld")
        #expect(overworld.map?.viewport == MapViewport(center: CGPoint(x: 100, y: -200), scale: 0.5))
        second.close(); overworld.close()
        await second.waitUntilClosed(); await overworld.waitUntilClosed()
    }
}

@Suite(.isolatedStores) struct LayerSearchTests {
    @Test func structuresPlacesAndCreatures() throws {
        func start(_ id: String, _ x: Int32) -> NBT {
            .compound(["id": .string(id), "ChunkX": .int(x), "ChunkZ": .int(0),
                       "Children": .list([.compound(["id": .string("minecraft:jigsaw"),
                                                   "BB": .intArray([x * 16, 60, 0, x * 16 + 9, 70, 9])])])])
        }
        let village = StructureMarker(try #require(StructureStart.starts(inChunk: .compound(["structures": .compound(["starts": .compound([
            "minecraft:village_plains": start("minecraft:village_plains", 2)])])])).first), groups: try StructureTagFixture.catalog())
        let wolf = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: 1, y: 64, z: 2, customName: "Summer", owner: UUID()), dimension: "minecraft:overworld"))
        let cat = try #require(CreatureMarker(Creature(id: "minecraft:cat", x: 5, y: 64, z: 5, owner: UUID()), dimension: "minecraft:overworld"))
        let villager = try #require(Creature(Fixtures.mob(["id": .string("minecraft:villager"), "Health": .float(20),
                                                         "Pos": .list([.double(9), .double(64), .double(9)]),
                                                         "VillagerData": .compound(["profession": .string("minecraft:farmer")])])))
        let farmer = try #require(CreatureMarker(villager, dimension: "minecraft:overworld"))
        let bed = PlaceMarker(PointOfInterest(type: "minecraft:home", x: 3, y: 64, z: 3, freeTickets: 1))
        let index = SearchIndex.overworld(DimensionContent(structures: [village],
                                placePoints: PointMarkers([bed]),
                                mobTypes: MobTypes([wolf, cat, farmer])))
        func search(_ query: String) -> [SearchHit] { WorldSearch.search(query, in: index, players: [], gameNames: .unavailable) { _ in .named("") } }
        #expect(search("structure:village").map { $0.title(in: .unavailable) } == ["Village Plains"])
        #expect(search("structure:village_plains").count == 1)
        #expect(search("structure:village").first?.source == .layer(.structure(.village), markerID: village.id))
        #expect(search("place:bed").map { $0.title(in: .unavailable) } == ["Bed"])
        #expect(search("pet:").map { $0.title(in: .unavailable) }.sorted() == ["Cat", "Summer"])
        #expect(search("pet:wolf").map { $0.title(in: .unavailable) } == ["Summer"])
        #expect(search("pet:cat").first?.detail(in: .unavailable) == "Pets")
        #expect(search("creature:").count == 3)
        #expect(search("villager:").map { $0.title(in: .unavailable) } == ["Farmer"])
        #expect(search("villager:").first?.detail(in: .unavailable) == "Villager")
        // Plain and filtered searches present the same creature without changing its selection identity or location.
        let named = try #require(search("summer").first)
        #expect(named.title(in: .unavailable) == wolf.name(in: .unavailable) && named.detail(in: .unavailable) == "Wolf")
        for query in ["pet:summer", "creature:summer", "pet:minecraft:wolf"] {
            let hit = try #require(search(query).first)
            #expect(hit.detail(in: .unavailable) == named.detail(in: .unavailable) && hit.title(in: .unavailable) == named.title(in: .unavailable))
            #expect(hit.id == named.id && hit.source == named.source)
            #expect(hit.dimension == named.dimension && hit.position == named.position && hit.y == named.y)
        }
        #expect(search("cat").isEmpty) // A plain search still excludes unnamed creatures.
    }

    @Test func tradeSearchFindsVillagersByWhatTheySellOrBuy() throws {
        func item(_ id: String, _ count: Int32, _ components: [String: NBT] = [:]) -> NBT {
            .compound(["id": .string(id), "count": .int(count), "components": .compound(components)])
        }
        let mendingBook = item("minecraft:enchanted_book", 1, ["minecraft:stored_enchantments": .compound(["minecraft:mending": .int(1)])])
        let librarian = try #require(Creature(Fixtures.mob([
            "id": .string("minecraft:villager"), "Health": .float(20), "Pos": .list([.double(30), .double(64), .double(-12)]),
            "VillagerData": .compound(["profession": .string("minecraft:librarian"), "level": .int(5)]),
            "Offers": .compound(["Recipes": .list([
                .compound(["buy": item("minecraft:emerald", 24), "buyB": item("minecraft:book", 1), "sell": mendingBook,
                           "uses": .int(0), "maxUses": .int(12)]),
                .compound(["buy": item("minecraft:emerald", 9), "sell": item("minecraft:bookshelf", 1),
                           "uses": .int(12), "maxUses": .int(12)]),
            ])]),
        ])))
        let marker = try #require(CreatureMarker(librarian, dimension: "minecraft:overworld"))
        let index = SearchIndex.overworld(DimensionContent(mobTypes: MobTypes([marker])))
        func search(_ query: String) -> [SearchHit] { WorldSearch.search(query, in: index, players: [], gameNames: .unavailable) { _ in .named("") } }
        let mending = search("trade:mending")
        #expect(mending.map { $0.title(in: .unavailable) } == ["Librarian"])
        #expect(GameNames.unavailable.profession(of: librarian, definitions: nil) == "Librarian, Level 5")
        // With no definition, the saved level stays visible even for a familiar vanilla ID.
        #expect(mending.first?.detail(in: .unavailable) == "1 Enchanted Book (Mending I) for 24 Emerald + 1 Book")
        #expect(mending.first?.position == CGPoint(x: 30, y: -12))
        #expect(mending.first?.source == .layer(.creature(.villager), markerID: marker.id))
        // Buying counts too, and sold-out trades say so.
        #expect(search("trade:emerald").first?.count == 2)
        #expect(search("trade:bookshelf").first?.detail(in: .unavailable) == "1 Bookshelf for 9 Emerald (sold out)")
        #expect(search("trade:diamond").isEmpty)
        #expect(GameNames.unavailable.enchantmentName("minecraft:sharpness", level: 5) == "Sharpness V")
    }
}

@Suite(.isolatedStores) struct BiomeSearchTests {
    func index() -> SearchIndex {
        var biomes: [ChunkPosition: String] = [:]
        for x in 0..<3 { for z in 0..<2 { biomes[ChunkPosition(x: x, z: z)] = "minecraft:pale_garden" } }   // 6 chunks
        for z in 5..<9 { biomes[ChunkPosition(x: 0, z: z)] = "minecraft:pale_garden" }                       // 4 chunks
        for z in 5..<9 { biomes[ChunkPosition(x: 3, z: z)] = "minecraft:plains" }
        return SearchIndex.overworld(DimensionContent(biomeAreas: BiomePresentation.areas(from: biomes)))
    }

    @Test func biomePrefixSearchesBiomeAreasLargestFirst() {
        let hits = WorldSearch.search("biome:pale garden", in: index(), players: [], gameNames: .unavailable) { _ in .named("") }
        #expect(hits.map(\.count) == [6, 4])
        #expect(hits.allSatisfy { hit in
            guard case .layer(.biome(let group), _) = hit.source else { return false }
            return hit.title(in: .unavailable) == "Pale Garden" && group == BiomeGroup(id: "minecraft:pale_garden")
        })
        #expect(hits.first?.detail(in: .unavailable) == "6 chunks")
        // The id works too, the prefix ignores case, and other searches don't list biomes.
        #expect(WorldSearch.search("Biome:pale_garden", in: index(), players: [], gameNames: .unavailable) { _ in .named("") }.count == 2)
        #expect(WorldSearch.search("biome:plains", in: index(), players: [], gameNames: .unavailable) { _ in .named("") }.map { $0.title(in: .unavailable) } == ["Plains"])
        #expect(WorldSearch.search("pale garden", in: index(), players: [], gameNames: .unavailable) { _ in .named("") }.isEmpty)
        // A filter on its own lists everything of its kind.
        #expect(WorldSearch.search("biome:", in: index(), players: [], gameNames: .unavailable) { _ in .named("") }.count == 3)
    }

    @Test func choosingABiomeResultOutlinesTheBiome() async throws {
        let chunks = (0..<2).flatMap { x in (0..<2).map { z in TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } } }
        let world = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "biome:plains"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        #expect(session.visibility.biomes.isEmpty)
        session.selection.choose(.hit(query: session.search.text, id: hit.id))
        #expect(session.visibility.biomes == [BiomeGroup(id: "minecraft:plains")])
        #expect(MapContent(session: session).biomeAreas.count == 1)
    }
}

extension SearchIndex {
    /// An index of the Overworld alone.
    static func overworld(_ part: DimensionContent) -> SearchIndex {
        SearchIndex(dimensions: ["minecraft:overworld": part])
    }
}
