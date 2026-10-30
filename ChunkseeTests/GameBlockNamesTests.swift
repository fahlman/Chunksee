import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameBlockNamesTests {
    private func game() throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us", "block.minecraft.stone": "Stone", "block.minecraft.water": "Water",
                "block.test.stone": "Other Stone", "block.test.new_block": "Newly Discovered Block",
                "block.test.path.wood": "Pack Wood", "item.test.untranslated": "Only An Item Name",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr", "block.minecraft.stone": "Pierre", "block.minecraft.water": "Eau",
                "block.test.stone": "Pierre",
            ]),
        ])
    }

    @Test func blockChoicesUseTranslatedNamesAndRawIDsWithStableCollisionOrder() async throws {
        let game = try game()
        defer { game.remove() }
        let names = GameNames(await (try game.library()).data.language("fr_FR", minecraftDirectory: game.root))
        let catalog: Set<String> = ["minecraft:stone", "test:stone", "minecraft:water", "test:new_block", "test:path/wood", "test:untranslated"]
        #expect(names.block("stone") == "Pierre" && names.block(":stone") == "Pierre")
        #expect(names.block("test:new_block") == "Newly Discovered Block")
        #expect(names.block("test:path/wood") == "Pack Wood")
        #expect(names.block("test:untranslated") == "Untranslated") // An item's key cannot name a block.
        #expect(names.blockIDs(in: catalog, matching: "pierre") == ["minecraft:stone", "test:stone"])
        #expect(names.blockIDs(in: catalog, matching: "minecraft:stone") == ["minecraft:stone"])
        #expect(names.blockIDs(in: catalog, matching: "newly discovered") == ["test:new_block"])
        #expect(names.blockIDs(in: catalog, matching: "test:path/") == ["test:path/wood"])
        #expect(names.blockIDs(in: catalog, matching: "untranslated") == ["test:untranslated"])
        #expect(Set(names.blockIDs(in: catalog, matching: "")) == catalog)
        #expect(names.blockIDs(in: catalog, matching: "absent").isEmpty)
        #expect(GameNames.unavailable.block("test:path/wood") == "Path Wood")
        #expect(GameNames.unavailable.blockIDs(in: catalog, matching: "stone") == ["minecraft:stone", "test:stone"])
        let limited = RegionTileRenderer.TopBlock(id: "minecraft:water", y: 63, waterDepth: RegionTileRenderer.maximumWaterDepth)
        #expect(names.blockDescription(limited, locale: Locale(identifier: "en_US")) == "Eau, at least 32 deep")
    }

    @Test func openWindowsRenameSavedBlockChoicesAndReadoutsWithoutChangingTheirFacts() async throws {
        let game = try game()
        let spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:water", "test:unused_block"]) { x, y, _ in
            y == 0 ? 1 : (x == 1 && y <= 3 ? 2 : 0)
        }
        let root = try TestWorld.make(chunks: [spec])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        let world = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { world.close() }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        await world.index.waitForIndex()
        let dimension = try #require(first.presentation.selectedDimension)
        let file = try RegionFile(contentsOf: dimension.regionURL(x: 0, z: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        let water = try #require(blocks[1])
        #expect(water.id == "minecraft:water" && water.y == 3 && water.waterDepth == 3)
        let palette = try #require(first.presentation.selectedIndex.shared?.paletteBlockIDs)
        #expect(palette.contains("test:unused_block"))
        let choices = MapBlockFilter(hiddenIDs: ["test:retired_block"], highlightedIDs: ["minecraft:water"])
        for session in [first, second] { session.map?.setBlockFilter(choices) }
        let catalog = palette.union(choices.hiddenIDs).union(choices.highlightedIDs)
        let original = MapContent(session: first), revision = world.index.revision
        let point = CGPoint(x: 1.5, y: 0.5)
        #expect(MapView.readout(at: point, block: water, biomes: nil, gameNames: original.gameNames) == "X 1  Y 3  Z 0 · Water, 3 deep")
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        for session in [first, second] {
            let current = MapContent(session: session)
            #expect(MapView.readout(at: point, block: water, biomes: nil, gameNames: current.gameNames) == "X 1  Y 3  Z 0 · Eau, 3 deep")
            #expect(current.gameNames.blockIDs(in: catalog, matching: "eau") == ["minecraft:water"])
            #expect(current.gameNames.blockIDs(in: catalog, matching: "minecraft:water") == ["minecraft:water"])
            #expect(current.gameNames.blockIDs(in: catalog, matching: "retired") == ["test:retired_block"])
            #expect(session.presentation.selectedIndex.shared?.paletteBlockIDs == palette)
            #expect(session.map?.blockFilter == choices && current.blockFilter == original.blockFilter)
        }
        #expect(world.index.revision == revision)
        #expect(original.gameNames.blockDescription(water) == "Water, 3 deep")
        #expect(GameNames.unavailable.blockDescription(water) == "Water, 3 deep")
        #expect(MapView.readout(at: point, block: nil, biomes: nil, gameNames: world.gameNames) == "X 1  Z 0")
        world.close()
        await world.waitUntilClosed()
        await names.minecraft.waitUntilIdle()
    }
}
