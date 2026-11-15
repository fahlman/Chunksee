import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct WorldSettingsTests {
    @Test func currentSettingsRestoreTogetherThroughDimensionSessions() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make(), overworld = "minecraft:overworld", nether = "minecraft:the_nether"
        let place = SavedPlace(name: "Home", dimension: overworld, x: -12, z: 34)
        let folder = try WorldFolders(defaults: defaults).remember(url)
        let settings = WorldSettings(folder: folder, defaults: defaults)
        var firstChoices = MapPresentation(), secondChoices = MapPresentation()
        firstChoices.depth = MapDepth(y: -23, isSurface: false)
        firstChoices.overlays.creatures = [.pet]
        firstChoices.overlays.showsGrid = true
        firstChoices.overlays.showsSlimeChunks = true
        secondChoices.depth = MapDepth(y: 40, isSurface: true)
        secondChoices.overlays.creatures = []
        secondChoices.overlays.showsTimeSpent = true
        settings.save(MapViewport(center: CGPoint(x: 120, y: -300), scale: 0.25),
                      presentation: firstChoices, for: overworld, selected: nether)
        settings.save(MapViewport(center: CGPoint(x: 15, y: -37), scale: 4),
                      presentation: secondChoices, for: nether, selected: nether)
        settings.savePlaces([place])
        let key = "worldSettings." + folder.id.uuidString
        let places = try #require(defaults.dictionary(forKey: key)?["places"] as? Data)
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
        first.map?.viewport.center = CGPoint(x: 123, y: -456)
        first.saveView()
        second.visibility.showsGrid = true
        #expect((defaults.dictionary(forKey: "worldSettings." + resources.settings.worldID.uuidString)?["places"] as? Data) == places)
        #expect(defaults.string(forKey: "playerNamesSentinel") == "app-wide sentinel" && !defaults.bool(forKey: "showsGrid"))
        let reopened = WorldSettings(id: resources.settings.worldID, defaults: defaults)
        #expect(reopened.lastDimension == nether && reopened.savedPlaces == [place])
        #expect(reopened.viewport(for: overworld)?.center == CGPoint(x: 123, y: -456))
        #expect(reopened.mapPresentation(for: nether).overlays.showsGrid)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(arguments: [false, true])
    func oldPathSettingsAreIgnoredWithoutRewritingThem(aggregated: Bool) throws {
        let defaults = TestDefaults.make(), id = UUID(), path = "/Old Preferences Only"
        let dimension = "minecraft:overworld"
        let places = try JSONEncoder().encode([SavedPlace(name: "Old", dimension: dimension, x: 1, z: 2)])
        let view: [String: Any] = ["dimension": "minecraft:the_nether", "views": [dimension: [1.0, 2.0, 4.0]]]
        let layers = [dimension: ["showsGrid": true]]
        if aggregated {
            defaults.set(view.merging(["places": places, "layers": layers]) { _, new in new },
                         forKey: "worldSettings." + path)
        } else {
            defaults.set(view, forKey: "mapView." + path)
            defaults.set(layers, forKey: "mapLayers." + path)
            defaults.set(places, forKey: "savedPlaces." + path)
        }
        let before = defaults.dictionaryRepresentation()
        let settings = WorldSettings(folder: .init(id: id, url: URL(fileURLWithPath: path)), defaults: defaults)
        #expect(settings.lastDimension == nil && settings.savedPlaces.isEmpty)
        #expect(settings.viewport(for: dimension) == nil && settings.mapPresentation(for: dimension) == MapPresentation())
        #expect(defaults.dictionary(forKey: "worldSettings." + id.uuidString) == nil)
        var choices = MapPresentation()
        choices.overlays.showsGrid = true
        settings.save(choices, for: dimension)
        #expect(WorldSettings(id: id, defaults: defaults).mapPresentation(for: dimension) == choices)
        for prefix in ["worldSettings.", "mapView.", "mapLayers.", "savedPlaces."] {
            let key = prefix + path
            if let value = before[key] {
                let actual = try #require(defaults.object(forKey: key))
                #expect(NSDictionary(dictionary: [key: actual]).isEqual(to: [key: value]))
            } else {
                #expect(defaults.object(forKey: key) == nil)
            }
        }
    }

    @Test func unreadableCurrentAnnotationsAreRetainedWhileOtherSettingsChange() {
        let defaults = TestDefaults.make(), id = UUID()
        let raw = Data("unreadable saved annotation payload".utf8)
        defaults.set(["version": 2, "places": raw], forKey: "worldSettings." + id.uuidString)
        let settings = WorldSettings(id: id, defaults: defaults)
        #expect(settings.savedPlaces.isEmpty)
        var choices = settings.mapPresentation(for: "minecraft:overworld")
        choices.overlays.showsGrid = true
        settings.save(MapViewport(), presentation: choices, for: "minecraft:overworld", selected: nil)
        let stored = defaults.dictionary(forKey: "worldSettings." + id.uuidString)
        #expect(stored?["places"] as? Data == raw && stored?["version"] as? Int == 2)
    }
}
