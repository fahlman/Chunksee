import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI
import Testing
@testable import MCWorld

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
        let index = SearchIndex(containers: ItemContainer.containers(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) })
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
        let index = SearchIndex(containers: ItemContainer.containers(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) },
                                signs: Sign.signs(inChunk: chunk).map { .init(dimension: "minecraft:overworld", value: $0) })
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
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        // The index is built as the world opens, before anyone searches.
        #expect(session.search.isIndexing)
        await session.search.waitForIndex()
        #expect(!session.search.isIndexing)
        session.search.text = "golden apple"
        #expect(session.search.results.map(\.detail) == ["2 Golden Apple"])
        session.show(session.search.results[0])
        #expect(session.search.selectedHitID == session.search.results[0].id)
        #expect(session.map?.viewport.center == CGPoint(x: 3.5, y: 4.5))
        session.search.text = "orchard"
        #expect(session.search.results.map(\.detail) == ["Orchard"])
        session.search.text = ""
        #expect(session.search.results.isEmpty)
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
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
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
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
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
