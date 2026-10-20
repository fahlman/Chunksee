import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct WorldSettingsTests {
    @Test func legacySettingsRestoreTogetherThroughDimensionSessionsAndImportOnlyOnce() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make(), overworld = "minecraft:overworld", nether = "minecraft:the_nether"
        let place = SavedPlace(name: "Home", dimension: overworld, x: -12, z: 34)
        let places = try JSONEncoder().encode([place])
        defaults.set(["dimension": nether, "views": [overworld: [120.0, -300.0, 0.25], nether: [15.0, -37.0, 4.0]],
                      "depths": [overworld: ["y": -23, "surface": 0], nether: ["y": 40, "surface": 1]]], forKey: "mapView." + url.path)
        defaults.set([overworld: ["shownCreatureGroups": ["pet"], "showsGrid": true, "showsSlimeChunks": true],
                      nether: ["shownCreatureGroups": [String](), "showsTimeSpent": true]], forKey: "mapLayers." + url.path)
        defaults.set(places, forKey: "savedPlaces." + url.path)
        defaults.set(false, forKey: "showsGrid")
        defaults.set("app-wide sentinel", forKey: "playerNamesSentinel")
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let first = WorldSession(resources: resources, dimensionID: overworld)
        let second = WorldSession(resources: resources, dimensionID: nether)
        defer { resources.close() }
        #expect(first.map?.viewport == MapViewport(center: CGPoint(x: 120, y: -300), scale: 0.25))
        #expect(second.map?.viewport == MapViewport(center: CGPoint(x: 15, y: -37), scale: 4))
        #expect(first.map?.depth == MapDepth(y: -23, isSurface: false) && second.map?.depth == MapDepth(y: 40, isSurface: true))
        #expect(resources.activeDimensionID == nether && first.savedPlaces === second.savedPlaces)
        #expect(first.savedPlaces.all == [place] && first.visibility.creatures == [.pet])
        #expect(second.visibility.creatures.isEmpty && first.visibility.showsGrid && !second.visibility.showsGrid)
        #expect(first.visibility.rememberedSlimeChunks && second.heatMap.isShown)
        for prefix in ["mapView.", "mapLayers.", "savedPlaces."] { #expect(defaults.object(forKey: prefix + url.path) == nil) }
        first.map?.viewport.center = CGPoint(x: 123, y: -456)
        first.saveView()
        second.visibility.showsGrid = true
        #expect((defaults.dictionary(forKey: "worldSettings." + url.path)?["places"] as? Data) == places)
        #expect(defaults.string(forKey: "playerNamesSentinel") == "app-wide sentinel" && !defaults.bool(forKey: "showsGrid"))
        // Once migrated, an obsolete writer cannot replace the new record on reopening.
        defaults.set(["dimension": overworld], forKey: "mapView." + url.path)
        let reopened = WorldSettings(world: url, defaults: defaults)
        #expect(reopened.lastDimension == nether && reopened.savedPlaces == [place])
        #expect(reopened.viewport(for: overworld)?.center == CGPoint(x: 123, y: -456))
        #expect(LayerVisibility(settings: reopened, dimension: nether).showsGrid)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func oneMoveMergesAllSettingsAndLaterSiblingSavesFollowTheMovedWorld() async throws {
        let defaults = TestDefaults.make(), old = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: old) }
        let new = old.appendingPathExtension("moved")
        let overworld = "minecraft:overworld", nether = "minecraft:the_nether", end = "minecraft:the_end"
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(old), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let source = resources.settings, target = WorldSettings(world: new, defaults: defaults)
        let annotations = resources.savedPlaces
        let place = try #require(annotations.add(name: "Original", dimension: overworld, at: CGPoint(x: 1, y: 2)))
        var duplicate = place; duplicate.name = "Existing destination"
        let other = SavedPlace(name: "End Base", dimension: end, x: 100, z: 200)
        target.savePlaces([duplicate, other])
        source.save(MapViewport(center: CGPoint(x: -5, y: 20), scale: 4), for: overworld, selected: overworld,
                    depth: MapDepth(y: -23, isSurface: false))
        target.save(MapViewport(center: CGPoint(x: 15, y: 30), scale: 2), for: end, selected: end)
        let sibling = LayerVisibility(settings: source, dimension: nether)
        sibling.creatures = []
        sibling.rememberTimeSpent(true)
        LayerVisibility(settings: target, dimension: end).showsGrid = true
        resources.relocateSettings(to: new)
        #expect(target.savedPlaces == [duplicate, other])
        #expect(target.depth(for: overworld) == MapDepth(y: -23, isSurface: false))
        #expect(target.viewport(for: overworld)?.center == CGPoint(x: -5, y: 20))
        #expect(target.viewport(for: end)?.center == CGPoint(x: 15, y: 30))
        #expect(LayerVisibility(settings: target, dimension: nether).rememberedTimeSpent)
        #expect(LayerVisibility(settings: target, dimension: end).showsGrid)
        sibling.showsGrid = true
        source.save(MapViewport(center: CGPoint(x: 7, y: -8), scale: 8), for: nether, selected: nether)
        #expect(LayerVisibility(settings: target, dimension: nether).showsGrid)
        #expect(target.viewport(for: nether)?.center == CGPoint(x: 7, y: -8) && target.lastDimension == nether)
        #expect(target.savedPlaces == [duplicate, other])
        #expect(annotations.all == [duplicate, other])
        let later = try #require(annotations.add(name: "Later", dimension: nether, at: .zero))
        #expect(target.savedPlaces == [duplicate, other, later])
        #expect(defaults.object(forKey: "worldSettings." + old.path) == nil)
        #expect(WorldSettings(world: URL(fileURLWithPath: "/Other World"), defaults: defaults).savedPlaces.isEmpty)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func unusableLegacyAnnotationsAreRetainedWhileOtherSettingsChange() {
        let defaults = TestDefaults.make(), url = URL(fileURLWithPath: "/Unreadable Annotations")
        let raw = Data("unreadable saved annotation payload".utf8)
        defaults.set(raw, forKey: "savedPlaces." + url.path)
        let settings = WorldSettings(world: url, defaults: defaults)
        #expect(settings.savedPlaces.isEmpty)
        settings.save(MapViewport(), for: "minecraft:overworld", selected: nil)
        LayerVisibility(settings: settings, dimension: "minecraft:overworld").showsGrid = true
        let stored = defaults.dictionary(forKey: "worldSettings." + url.path)
        #expect(stored?["places"] as? Data == raw && stored?["version"] as? Int == 1)
    }
}
