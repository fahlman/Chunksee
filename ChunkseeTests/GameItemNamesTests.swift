import ChunkseeIndex
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameItemNamesTests {
    @Test func translatedItemsKeepLiteralNamesSearchIdentityAndStorageCounts() async throws {
        let french = try await EnchantmentNameFixture.names("fr_FR")
        let english = try await EnchantmentNameFixture.names()
        var token = ItemStack(id: "test:token", count: 2)
        token.customName = #"{"text":"Kept literally"}"#
        #expect(french.itemName(of: token) == "2 Jeton “\(token.customName!)”")
        #expect(french.itemLabel(kind: "test:box", customName: "Supplies") == "Pack Box “Supplies”")
        #expect(french.itemLabel(kind: "test:unknown_item", customName: nil) == "Unknown Item")
        for query in ["jeton", "test:token", "kept literally"] {
            let found = try #require(WorldSearch.summary(of: [token], query: SearchQuery(query), gameNames: french))
            #expect(found.count == 2 && found.items.map(\.id) == ["test:token"])
            #expect(found.text(in: french) == french.itemName(of: token, includingOne: true))
        }
        let containers = ItemContainer.containers(inChunk: .compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
                "Items": .list([ItemLabelTests().item("test:token", count: 7)])]),
        ])]))
        let totals = StoredItemTotal.totals(in: containers)
        let first = english.storedItems(totals), second = french.storedItems(totals)
        #expect(first.map(\.name) == ["Trade Token"] && second.map(\.name) == ["Jeton"])
        #expect(first.map(\.id) == second.map(\.id) && first.map(\.count) == [7])
        #expect(first.map(\.count) == second.map(\.count) && second.map(\.containers) == [1])
    }

    @Test func worldDefinitionReplacementUpdatesNamesAndQueriesWithoutChangingLanguage() async throws {
        let game = try EnchantmentNameFixture.game()
        let replacement = try ItemPictureFixture(extraFiles: [
            "data/test/enchantment/ward.json": ItemPictureFixture.json([
                "description": ["text": "Revised Ward"], "max_level": 1, "slots": ["any"], "effects": [:],
            ]),
        ])
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let root = try TestWorld.make(chunks: [chunk])
        defer { game.remove(); replacement.remove(); try? FileManager.default.removeItem(at: root) }
        let saved = try World(contentsOf: root), dimension = try #require(saved.dimension("minecraft:overworld"))
        let trader = Fixtures.mob([
            "id": .string("minecraft:villager"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]),
            "VillagerData": .compound(["profession": .string("minecraft:librarian"), "level": .int(1)]),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": ItemLabelTests().item("test:token", count: 3),
                "sell": ItemLabelTests().item("minecraft:enchanted_book", extra: [
                    "minecraft:stored_enchantments": .compound(["test:ward": .int(1)]),
                ]),
            ])])]),
        ])
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        let entities = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([trader])])
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: entities)]))
            .write(to: dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make(), players = PlayerNames(defaults: TestDefaults.make())
        players.minecraft.choose(game.root)
        let world = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: players,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { world.close() }
        world.waitBeforeRefresh = { _ in }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        world.savedSearches.add("trade:")
        world.savedSearches.add("trade:warding")
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] { await session.search.waitForSearch() }
        let before = world.gameNames
        let original = try #require(first.search.results(for: "trade:").first)
        #expect(original.detail(in: before) == "1 Enchanted Book (Warding I) for 3 Trade Token")
        #expect(first.search.results(for: "trade:warding").count == 1)

        let assets = try #require(try GameAssets(contentsOf: replacement.jar))
        let replacementDefinitions = try saved.enchantmentDefinitions(assets: assets)
        let ward: EnchantmentDefinition = try #require(replacementDefinitions["test:ward"])
        var updated = world.details.definitions
        updated.enchantments["test:ward"] = ward
        let gate = AsyncReadGate<WorldDefinitions>()
        world.readDefinitions = { _, _, _ in .complete(await gate.read("definitions")) }
        world.worldChanged([root.appendingPathComponent("datapacks/changed.zip")])
        await gate.waitForRequest("definitions")
        #expect(world.gameNames.identity == before.identity)
        await gate.finish("definitions", with: updated)
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] {
            await session.search.waitForSearch()
            let result = try #require(session.search.results(for: "trade:").first)
            #expect(result.id == original.id && result.count == original.count)
            #expect(result.detail(in: world.gameNames) == "1 Enchanted Book (Revised Ward) for 3 Trade Token")
            #expect(session.search.results(for: "trade:warding").isEmpty)
        }
        #expect(world.gameNames.identity?.language == before.identity?.language)
        #expect(world.gameNames.identity?.enchantments != before.identity?.enchantments)
        #expect(before.enchantmentName("test:ward", level: 1) == "Warding I")
        #expect(world.gameNames.enchantmentName("test:ward", level: 1) == "Revised Ward")
        let completed = world.gameNames.identity
        world.worldChanged([root.appendingPathComponent("datapacks/unchanged.zip")])
        await gate.waitForRequest("definitions", count: 2)
        await gate.finish("definitions", with: updated)
        await world.waitForRefresh()
        #expect(world.gameNames.identity == completed)
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            let result = try #require(session.search.results(for: "trade:").first)
            #expect(result.id == original.id && result.count == original.count)
            #expect(result.detail(in: world.gameNames) == "1 Enchanted Book (Revised Ward) for 3 Jeton")
        }
        #expect(world.gameNames.identity?.language != completed?.language)
        #expect(world.gameNames.identity?.enchantments == completed?.enchantments)
        world.close()
        #expect(world.gameNames.identity == nil)
        await world.waitUntilClosed()
        await players.minecraft.waitUntilIdle()
    }
}
