import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionVisibilityTests {
    @Test func dimensionTabsRetainTheirOwnControlsWhenAnotherTabChangesAndAfterReopening() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)

        let defaults = TestDefaults.make()

        let hidden = UUID()
        func sessions() async throws -> [WorldSession] {
            let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                           savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
            return [WorldSession(resources: resources, dimensionID: "minecraft:overworld"),
                    WorldSession(resources: resources, dimensionID: "minecraft:the_nether")]
        }
        let opened = try await sessions()
        defer { opened.forEach { $0.close() } }
        let overworld = opened[0], nether = opened[1]
        overworld.visibility.structures = [.mineshaft]
        overworld.visibility.places = [.portal]
        overworld.visibility.creatures = [.pet]
        overworld.visibility.biomes = [BiomeGroup(id: "minecraft:plains")]
        overworld.visibility.hiddenPlayers = [hidden]
        overworld.visibility.showsGrid = true
        overworld.heatMap.isShown = true
        nether.visibility.structures = []
        nether.visibility.places = []
        nether.visibility.creatures = []
        nether.visibility.biomes = [BiomeGroup(id: "minecraft:nether_wastes")]
        nether.visibility.hiddenPlayers = []
        nether.visibility.showsGrid = false
        nether.heatMap.isShown = true
        nether.heatMap.isShown = false
        #expect(overworld.mapContent.showsGrid && !nether.mapContent.showsGrid)
        #expect(overworld.heatMap.isShown && !nether.heatMap.isShown)
        #expect(overworld.visibility.hiddenPlayers == [hidden] && nether.visibility.hiddenPlayers.isEmpty)
        #expect(overworld.visibility.structures == [.mineshaft] && nether.visibility.structures.isEmpty)
        opened.forEach { $0.close() }
        for session in opened { await session.waitUntilClosed() }

        let reopened = try await sessions()
        defer { reopened.forEach { $0.close() } }
        let restored = reopened[0], restoredNether = reopened[1]
        #expect(restored.visibility.structures == [.mineshaft] && restoredNether.visibility.structures.isEmpty)
        #expect(restored.visibility.places == [.portal] && restoredNether.visibility.places.isEmpty)
        #expect(restored.visibility.creatures == [.pet] && restoredNether.visibility.creatures.isEmpty)
        #expect(restored.visibility.biomes == [BiomeGroup(id: "minecraft:plains")])
        #expect(restoredNether.visibility.biomes == [BiomeGroup(id: "minecraft:nether_wastes")])
        #expect(restored.visibility.hiddenPlayers == [hidden] && restoredNether.visibility.hiddenPlayers.isEmpty)
        #expect(restored.mapContent.showsGrid && !restoredNether.mapContent.showsGrid)
        #expect(restored.heatMap.isShown && !restoredNether.heatMap.isShown)
        await restored.heatMap.waitForReads()
        #expect(restored.heatMap.visibleImages != nil && !restored.heatMap.isLoading)
        #expect(defaults.object(forKey: "showsGrid") == nil && defaults.object(forKey: "hiddenPlayers") == nil)
        reopened.forEach { $0.close() }
        for session in reopened { await session.waitUntilClosed() }
    }

    @Test func oldPreferencesSeedEachDimensionOnceWithoutBecomingSharedLiveSettings() {

        let defaults = TestDefaults.make()

        let url = URL(fileURLWithPath: "/Visibility Migration")
        defaults.set(["mineshaft"], forKey: "shownStructureGroups")
        defaults.set([String](), forKey: "shownCreatureGroups")
        defaults.set(true, forKey: "showsGrid")
        let overworld = LayerVisibility(world: url, dimension: "minecraft:overworld", defaults: defaults)
        #expect(overworld.structures == [.mineshaft] && overworld.creatures.isEmpty && overworld.showsGrid)
        overworld.structures = []
        overworld.showsGrid = false
        let nether = LayerVisibility(world: url, dimension: "minecraft:the_nether", defaults: defaults)
        #expect(nether.structures == [.mineshaft] && nether.creatures.isEmpty && nether.showsGrid)
        #expect(defaults.bool(forKey: "showsGrid") && defaults.stringArray(forKey: "shownStructureGroups") == ["mineshaft"])
        defaults.set(["villager"], forKey: "shownCreatureGroups")
        defaults.set(false, forKey: "showsGrid")
        #expect(LayerVisibility(world: url, dimension: "minecraft:overworld", defaults: defaults).creatures.isEmpty)
        #expect(LayerVisibility(world: url, dimension: "minecraft:the_nether", defaults: defaults).showsGrid)
    }

    @Test func worldsAreIndependentAndRelocationPreservesEveryDimension() {

        let defaults = TestDefaults.make()

        let first = URL(fileURLWithPath: "/First World"), second = URL(fileURLWithPath: "/Second World")
        let moved = URL(fileURLWithPath: "/Moved World")
        let overworld = LayerVisibility(world: first, dimension: "minecraft:overworld", defaults: defaults)
        let nether = LayerVisibility(world: first, dimension: "minecraft:the_nether", defaults: defaults)
        overworld.showsGrid = true
        overworld.creatures = [.pet]
        nether.creatures = []
        nether.rememberTimeSpent(true)
        let other = LayerVisibility(world: second, dimension: "minecraft:overworld", defaults: defaults)
        #expect(!other.showsGrid && !other.rememberedTimeSpent)
        LayerVisibility(world: moved, dimension: "minecraft:the_end", defaults: defaults).showsGrid = true
        overworld.relocate(to: moved)
        let restored = LayerVisibility(world: moved, dimension: "minecraft:overworld", defaults: defaults)
        let restoredNether = LayerVisibility(world: moved, dimension: "minecraft:the_nether", defaults: defaults)
        #expect(restored.showsGrid && restored.creatures == [.pet])
        #expect(restoredNether.creatures.isEmpty && restoredNether.rememberedTimeSpent)
        #expect(LayerVisibility(world: moved, dimension: "minecraft:the_end", defaults: defaults).showsGrid)
        #expect(!other.showsGrid && !other.rememberedTimeSpent)
        #expect(defaults.dictionary(forKey: "mapLayers." + first.path) == nil)
    }
}
