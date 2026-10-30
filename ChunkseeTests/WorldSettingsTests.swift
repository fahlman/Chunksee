import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
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
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
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
        #expect(first.visibility.showsSlimeChunks && second.heatMap.isShown)
        for prefix in ["mapView.", "mapLayers.", "savedPlaces."] { #expect(defaults.object(forKey: prefix + url.path) == nil) }
        first.map?.viewport.center = CGPoint(x: 123, y: -456)
        first.saveView()
        second.visibility.showsGrid = true
        #expect((defaults.dictionary(forKey: "worldSettings." + resources.settings.worldID.uuidString)?["places"] as? Data) == places)
        #expect(defaults.string(forKey: "playerNamesSentinel") == "app-wide sentinel" && !defaults.bool(forKey: "showsGrid"))
        // Once migrated, an obsolete writer cannot replace the new record on reopening.
        defaults.set(["dimension": overworld], forKey: "mapView." + url.path)
        let reopened = WorldSettings(id: resources.settings.worldID, defaults: defaults)
        #expect(reopened.lastDimension == nether && reopened.savedPlaces == [place])
        #expect(reopened.viewport(for: overworld)?.center == CGPoint(x: 123, y: -456))
        #expect(reopened.mapPresentation(for: nether).overlays.showsGrid)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func unusableLegacyAnnotationsAreRetainedWhileOtherSettingsChange() {
        let defaults = TestDefaults.make(), id = UUID(), path = "/Unreadable Annotations"
        let raw = Data("unreadable saved annotation payload".utf8)
        defaults.set(raw, forKey: "savedPlaces." + path)
        let settings = WorldSettings(id: id, defaults: defaults, legacyPaths: [path])
        #expect(settings.savedPlaces.isEmpty)
        var choices = settings.mapPresentation(for: "minecraft:overworld")
        choices.overlays.showsGrid = true
        settings.save(MapViewport(), presentation: choices, for: "minecraft:overworld", selected: nil)
        let stored = defaults.dictionary(forKey: "worldSettings." + id.uuidString)
        #expect(stored?["places"] as? Data == raw && stored?["version"] as? Int == 2)
    }
}
