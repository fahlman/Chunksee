import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionVisibilityTests {
    @Test func savedPlaceVisibilityFiltersTheMapButKeepsAnnotationsAndRestoresPerDimension() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = TestDefaults.make(), worldID = UUID()
        // A missing choice defaults independently of the other current-format choices.
        let record = try JSONSerialization.data(withJSONObject:
            ["version": 1, "presentation": ["overlays": ["showsGrid": true]]])
        defaults.set(["version": 2, "mapPresentations": ["minecraft:overworld": record]],
                     forKey: "worldSettings." + worldID.uuidString)
        func open() async throws -> WorldResources {
            let names = PlayerNames(defaults: defaults)
            let prepared = try await WorldPreparation.read(WorldSnapshot.read(url), minecraft: names.minecraft)
            return WorldResources(prepared: prepared, names: names,
                               savedSearches: SavedSearches(defaults: defaults),
                               settings: WorldSettings(id: worldID, defaults: defaults), cacheRoot: nil,
                               watchWorld: { _, _ in nil })
        }
        let resources = try await open()
        defer { resources.close() }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let home = try #require(resources.savedPlaces.add(name: "Home", dimension: "minecraft:overworld", at: CGPoint(x: -100, y: 100)))
        let fortress = try #require(resources.savedPlaces.add(name: "Fortress", dimension: "minecraft:the_nether", at: .zero))
        let viewport = MapViewport(center: home.mapPosition, scale: 2), size = CGSize(width: 200, height: 200)
        let center = CGPoint(x: 100, y: 100)
        #expect(overworld.visibility.showsSavedPlaces && nether.visibility.showsSavedPlaces)
        #expect(MapContent(session: overworld).target(at: center, viewport: viewport, size: size) == .row(.savedPlace(home.id)))
        overworld.visibility.showsSavedPlaces = false
        let hidden = MapContent(session: overworld)
        #expect(hidden.savedPlaces.isEmpty && MapContent(session: nether).savedPlaces == [fortress])
        #expect(hidden.target(at: center, viewport: viewport, size: size) != .row(.savedPlace(home.id)))
        #expect(!hidden.accessibleLocations(viewport: viewport, size: size).contains { $0.target == .row(.savedPlace(home.id)) })
        #expect(overworld.annotations.listedPlaces == [home] && resources.savedPlaces.all == [home, fortress])
        overworld.selection.choose(.savedPlace(home.id))
        #expect(overworld.visibility.showsSavedPlaces && MapContent(session: overworld).savedPlaces == [home])
        #expect(overworld.selection.sidebarSelection == .savedPlace(home.id))
        overworld.visibility.showsSavedPlaces = false
        resources.close()
        await resources.waitUntilClosed()
        overworld.annotations.visit(home)
        #expect(!overworld.visibility.showsSavedPlaces)

        let reopened = try await open()
        defer { reopened.close() }
        let restored = WorldSession(resources: reopened, dimensionID: "minecraft:overworld")
        let restoredNether = WorldSession(resources: reopened, dimensionID: "minecraft:the_nether")
        #expect(!restored.visibility.showsSavedPlaces && restoredNether.visibility.showsSavedPlaces)
        #expect(MapContent(session: restored).savedPlaces.isEmpty && MapContent(session: restoredNether).savedPlaces == [fortress])
        #expect(restored.annotations.listedPlaces == [home] && restored.visibility.showsGrid)
        #expect(defaults.object(forKey: "showsSavedPlaces") == nil)
        reopened.close()
        await reopened.waitUntilClosed()
    }

    @Test func dimensionTabsRetainTheirOwnControlsWhenAnotherTabChangesAndAfterReopening() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)

        let defaults = TestDefaults.make()

        let hidden = UUID()
        func sessions() async throws -> [WorldSession] {
            let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
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
        overworld.visibility.showsTimeSpent = true
        nether.visibility.structures = []
        nether.visibility.places = []
        nether.visibility.creatures = []
        nether.visibility.biomes = [BiomeGroup(id: "minecraft:nether_wastes")]
        nether.visibility.hiddenPlayers = []
        nether.visibility.showsGrid = false
        nether.visibility.showsTimeSpent = true
        nether.visibility.showsTimeSpent = false
        #expect(MapContent(session: overworld).showsGrid && !MapContent(session: nether).showsGrid)
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
        #expect(MapContent(session: restored).showsGrid && !MapContent(session: restoredNether).showsGrid)
        #expect(restored.heatMap.isShown && !restoredNether.heatMap.isShown)
        await restored.heatMap.waitForReads()
        #expect(restored.heatMap.visibleImages != nil && !restored.heatMap.isLoading)
        #expect(defaults.object(forKey: "showsGrid") == nil && defaults.object(forKey: "hiddenPlayers") == nil)
        reopened.forEach { $0.close() }
        for session in reopened { await session.waitUntilClosed() }
    }

    @Test func oldGlobalPreferencesDoNotSeedAnyDimension() {

        let defaults = TestDefaults.make()

        let id = UUID()
        defaults.set(["mineshaft"], forKey: "shownStructureGroups")
        defaults.set([String](), forKey: "shownCreatureGroups")
        defaults.set(true, forKey: "showsGrid")
        let settings = WorldSettings(id: id, defaults: defaults)
        var overworld = settings.mapPresentation(for: "minecraft:overworld")
        #expect(overworld == MapPresentation())
        overworld.overlays.structures = []
        overworld.overlays.creatures = []
        overworld.overlays.showsGrid = true
        settings.save(overworld, for: "minecraft:overworld")
        let nether = WorldSettings(id: id, defaults: defaults).mapPresentation(for: "minecraft:the_nether").overlays
        #expect(nether == LayerVisibility())
        #expect(defaults.bool(forKey: "showsGrid") && defaults.stringArray(forKey: "shownStructureGroups") == ["mineshaft"])
        defaults.set(["villager"], forKey: "shownCreatureGroups")
        defaults.set(false, forKey: "showsGrid")
        #expect(WorldSettings(id: id, defaults: defaults).mapPresentation(for: "minecraft:overworld").overlays.creatures.isEmpty)
        #expect(WorldSettings(id: id, defaults: defaults).mapPresentation(for: "minecraft:the_nether").overlays == LayerVisibility())
    }

    @Test func worldsAreIndependentAndReopeningPreservesEveryDimension() {

        let defaults = TestDefaults.make()

        let first = UUID(), second = UUID()
        let settings = WorldSettings(id: first, defaults: defaults)
        var overworld = settings.mapPresentation(for: "minecraft:overworld")
        var nether = settings.mapPresentation(for: "minecraft:the_nether")
        overworld.overlays.showsGrid = true
        overworld.overlays.creatures = [.pet]
        nether.overlays.creatures = []
        nether.overlays.showsTimeSpent = true
        settings.save(overworld, for: "minecraft:overworld")
        settings.save(nether, for: "minecraft:the_nether")
        let other = WorldSettings(id: second, defaults: defaults).mapPresentation(for: "minecraft:overworld").overlays
        #expect(!other.showsGrid && !other.showsTimeSpent)
        var end = settings.mapPresentation(for: "minecraft:the_end")
        end.overlays.showsGrid = true
        settings.save(end, for: "minecraft:the_end")
        let restored = WorldSettings(id: first, defaults: defaults).mapPresentation(for: "minecraft:overworld").overlays
        let restoredNether = WorldSettings(id: first, defaults: defaults).mapPresentation(for: "minecraft:the_nether").overlays
        #expect(restored.showsGrid && restored.creatures == [.pet])
        #expect(restoredNether.creatures.isEmpty && restoredNether.showsTimeSpent)
        #expect(WorldSettings(id: first, defaults: defaults).mapPresentation(for: "minecraft:the_end").overlays.showsGrid)
        #expect(!other.showsGrid && !other.showsTimeSpent)
    }
}
