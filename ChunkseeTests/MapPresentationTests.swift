import ChunkseeKit
import ChunkseeIndex
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapPresentationTests {
    @Test(arguments: [false, true])
    func shownOnlyGroupListsUseDefaultsWithoutRewritingSavedRecords(empty: Bool) throws {
        let defaults = TestDefaults.make(), id = UUID(), dimension = "minecraft:overworld", other = "test:other"
        let key = "worldSettings." + id.uuidString, annotations = Data("opaque annotations".utf8)
        let oldRecord = try JSONSerialization.data(withJSONObject: [
            "viewport": [12.0, -9, 2], "presentation": [
                "style": "height", "depth": ["y": 40, "isSurface": false], "castsShadows": false,
                "overlays": [
                    "structures": ["village": false, "mineshaft": true, "abandonedCamp": false],
                    "places": empty ? [] : ["spawner", "unfamiliar"],
                    "creatures": empty ? [] : ["pet", "unfamiliar"], "showsGrid": true
                ]
            ]
        ])
        defaults.set(["dimension": other, "places": annotations,
                      "mapPresentations": [dimension: oldRecord, other: oldRecord]], forKey: key)
        let settings = WorldSettings(id: id, defaults: defaults)
        let choices = settings.mapPresentation(for: dimension)
        #expect(choices.style == .height && choices.depth == MapDepth(y: 40, isSurface: false))
        #expect(!choices.castsShadows && choices.overlays.showsGrid)
        #expect(!choices.overlays.structures.contains(.village) && choices.overlays.structures.contains(.mineshaft))
        #expect(!choices.overlays.structures.contains(.abandonedCamp))
        #expect(choices.overlays.places == LayerVisibility().places)
        #expect(choices.overlays.creatures == LayerVisibility().creatures)
        #expect(settings.viewport(for: dimension) == MapViewport(center: CGPoint(x: 12, y: -9), scale: 2))
        let stored = try #require(defaults.dictionary(forKey: key))
        let records = try #require(stored["mapPresentations"] as? [String: Data])
        #expect(records[dimension] == oldRecord && records[other] == oldRecord)
        #expect(stored["places"] as? Data == annotations)
        #expect(settings.lastDimension == other)

        let reopened = WorldSettings(id: id, defaults: defaults)
        #expect(reopened.mapPresentation(for: dimension) == choices)
        #expect((defaults.dictionary(forKey: key)?["mapPresentations"] as? [String: Data])?[dimension] == oldRecord)
        #expect((defaults.dictionary(forKey: key)?["mapPresentations"] as? [String: Data])?[other] == oldRecord)
    }

    @Test func explicitGroupChoicesUseDefaultsOnlyForMissingGroups() throws {
        let defaults = TestDefaults.make(), id = UUID(), dimension = "minecraft:overworld"
        let key = "worldSettings." + id.uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "presentation": ["overlays": [
                "structures": ["village": false, "mineshaft": true],
                "places": ["portal": false, "spawner": true],
                "creatures": ["named": false, "mob": true]
            ]]
        ])
        defaults.set(["mapPresentations": [dimension: data]], forKey: key)
        let settings = WorldSettings(id: id, defaults: defaults)
        var choices = settings.mapPresentation(for: dimension)
        #expect(!choices.overlays.structures.contains(.village) && choices.overlays.structures.contains(.mineshaft))
        #expect(choices.overlays.structures.contains(.abandonedCamp) && !choices.overlays.structures.contains(.netherFossil))
        #expect(choices.overlays.places == [.bell, .lodestone, .spawner])
        #expect(choices.overlays.creatures == [.pet, .mob])
        choices.overlays.structures = []
        choices.overlays.places = []
        choices.overlays.creatures = []
        settings.save(choices, for: dimension)
        #expect(WorldSettings(id: id, defaults: defaults).mapPresentation(for: dimension) == choices)
    }

    @Test func separateMapFieldsAreIgnoredAndCurrentWorldDataIsPreserved() throws {
        let defaults = TestDefaults.make(), id = UUID(), player = UUID()
        let key = "worldSettings." + id.uuidString, dimension = "minecraft:overworld", other = "minecraft:the_nether"
        let annotations = Data("opaque annotations".utf8)
        defaults.set([
            "dimension": other, "places": annotations, "shownVersionNotices": ["kept notice"],
            "views": [dimension: [-12.5, 33, 2], other: [7.0, 8, 4]],
            "depths": [dimension: ["y": -23, "surface": 0]], "styles": [dimension: "height"],
            "blockFilters": [dimension: ["enabled": false, "hidden": ["stone", "bad:id:bad"], "highlighted": ["sand", "stone"]]],
            "lightingModes": [dimension: "daylight"], "castsShadows": [dimension: false], "biomeBlending": [dimension: true],
            "layers": [dimension: [
                "structureVisibility": ["village": false, "mineshaft": true], "shownPlaceGroups": ["spawner"],
                "shownCreatureGroups": ["pet"], "shownMobTypes": ["minecraft:sheep"], "shownBiomeGroups": ["test:wetland"],
                "hiddenPlayers": [player.uuidString, "invalid UUID"], "showsGrid": true, "showsSavedPlaces": false,
                "showsWorldBorder": false, "showsTimeSpent": true, "showsSlimeChunks": true, "showsDarkSpots": true
            ], other: ["showsGrid": false]]
        ], forKey: key)
        let before = try #require(defaults.dictionary(forKey: key))
        let settings = WorldSettings(id: id, defaults: defaults)
        #expect(settings.mapPresentation(for: dimension) == MapPresentation())
        #expect(settings.viewport(for: dimension) == nil)
        #expect(settings.lastDimension == other && settings.hasShownVersionNotice("kept notice"))
        let unchanged = try #require(defaults.dictionary(forKey: key))
        #expect(NSDictionary(dictionary: unchanged).isEqual(to: before))

        var choices = MapPresentation()
        choices.style = .waterDepth
        choices.overlays.showsGrid = true
        settings.save(MapViewport(center: .zero, scale: 4), presentation: choices, for: dimension, selected: other)
        #expect(settings.mapPresentation(for: dimension) == choices && settings.viewport(for: dimension)?.scale == 4)
        let saved = try #require(defaults.dictionary(forKey: key))
        #expect(saved["places"] as? Data == annotations)
        for section in ["views", "depths", "styles", "blockFilters", "lightingModes", "castsShadows", "biomeBlending", "layers"] {
            let actual = try #require(saved[section] as? [String: Any])
            let previous = try #require(before[section] as? [String: Any])
            #expect(NSDictionary(dictionary: actual).isEqual(to: previous))
        }
    }

    @Test func unreadableChoicesKeepReadableSiblingsAndOtherDimensionRecords() throws {
        let defaults = TestDefaults.make(), id = UUID(), dimension = "minecraft:overworld"
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "viewport": [0, 0, -1], "presentation": [
                "style": "future-style", "depth": ["y": 40, "isSurface": false], "castsShadows": false,
                "lightingMode": "unfamiliar", "blendsBiomeColors": true,
                "blockFilter": ["hiddenIDs": ["stone", "bad:id:bad"], "highlightedIDs": ["stone", "sand"]],
                "overlays": ["showsGrid": true, "showsTimeSpent": "invalid", "shownFutureLayer": true]
            ]
        ])
        let key = "worldSettings." + id.uuidString
        defaults.set(["mapPresentations": [dimension: data, "test:unreadable": "keep opaque sibling"]], forKey: key)
        let settings = WorldSettings(id: id, defaults: defaults), choices = settings.mapPresentation(for: dimension)
        #expect(choices.style == MapPresentation().style && choices.lightingMode == MapPresentation().lightingMode)
        #expect(choices.depth == MapDepth(y: 40, isSurface: false) && !choices.castsShadows && choices.blendsBiomeColors)
        #expect(choices.blockFilter == MapBlockFilter(hiddenIDs: ["minecraft:stone"], highlightedIDs: ["minecraft:sand"]))
        #expect(choices.overlays.showsGrid && !choices.overlays.showsTimeSpent && choices.overlays.showsSavedPlaces)
        #expect(settings.viewport(for: dimension) == nil)
        settings.save(choices, for: dimension)
        #expect((defaults.dictionary(forKey: key)?["mapPresentations"] as? [String: Any])?["test:unreadable"] as? String == "keep opaque sibling")
    }

    @Test func aSessionSavesAllChoicesWithoutAViewAndRestoresOnlyPersistentOverlays() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        let defaults = TestDefaults.make(), id = UUID(), dimension = "minecraft:overworld", other = "minecraft:the_nether"
        func open() async throws -> WorldResources {
            let names = PlayerNames(defaults: defaults)
            let prepared = try await WorldPreparation.read(WorldSnapshot.read(root), minecraft: names.minecraft)
            return WorldResources(prepared: prepared, names: names, savedSearches: SavedSearches(defaults: defaults),
                settings: WorldSettings(id: id, defaults: defaults), cacheRoot: nil, watchWorld: { _, _ in nil })
        }
        let resources = try await open()
        defer { resources.close() }
        let session = WorldSession(resources: resources, dimensionID: dimension)
        let sibling = WorldSession(resources: resources, dimensionID: other)
        sibling.becameActive()
        let map = try #require(session.map)
        map.setDepth(MapDepth(y: -31, isSurface: false))
        map.setStyle(.height)
        map.setBiomeBlending(true)
        map.setLightingMode(.daylight)
        map.setCastsShadows(false)
        map.setBlockFilter(MapBlockFilter(hiddenIDs: ["minecraft:stone"]))
        session.visibility.showsGrid = true
        session.visibility.showsTimeSpent = true
        session.visibility.showsSlimeChunks = true
        session.setDarkSpots(true)
        session.visibility.showsSavedPlaces = false
        session.visibility.showsWorldBorder = false
        session.visibility.structures = [.mineshaft]
        session.visibility.places = [.spawner]
        session.visibility.creatures = [.villager]
        session.visibility.mobTypes = ["minecraft:sheep"]
        session.visibility.mobAppearances["minecraft:sheep"] = MobAppearance(nil)
        var expected = map.presentation
        expected.overlays.mobAppearances = [:]
        let saved = WorldSettings(id: id, defaults: defaults)
        #expect(saved.mapPresentation(for: dimension) == expected)
        #expect(saved.lastDimension == other && sibling.map?.presentation == MapPresentation())
        #expect(session.heatMap.isShown && session.slimeChunks.isShown)
        await session.heatMap.waitForReads()
        await session.slimeChunks.waitForImages()
        #expect(!session.heatMap.isLoading && !session.slimeChunks.isLoading)
        let viewport = MapViewport(center: CGPoint(x: 8, y: -12), scale: 4)
        map.viewport = viewport
        resources.close()
        await resources.waitUntilClosed()

        let reopened = try await open()
        defer { reopened.close() }
        let restored = WorldSession(resources: reopened, dimensionID: dimension)
        #expect(restored.map?.presentation == expected && restored.map?.viewport == viewport)
        #expect(restored.visibility.mobAppearances.isEmpty && restored.heatMap.isShown && restored.slimeChunks.isShown)
        #expect(reopened.settings.lastDimension == other)
        reopened.close()
        await reopened.waitUntilClosed()
        restored.visibility.showsGrid = false
        restored.map?.setStyle(.normal)
        #expect(saved.mapPresentation(for: dimension) == expected)
    }

    @Test func unavailableDimensionTransfersItsChoicesIntoTheMapWhenItsSourceAppears() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), id = "test:later"
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let session = WorldSession(resources: resources, dimensionID: id)
        #expect(session.map == nil)
        session.visibility.showsGrid = true
        session.visibility.showsTimeSpent = true
        session.visibility.mobTypes = ["test:creature"]
        session.visibility.mobAppearances["test:creature"] = MobAppearance(nil)
        #expect(resources.settings.mapPresentation(for: id).overlays.showsGrid)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dimensions/test/later/region"),
                                                withIntermediateDirectories: true)
        try await resources.replaceSource(from: WorldSnapshot.read(root))
        let map = try #require(session.map)
        #expect(map.presentation.overlays == session.visibility)
        #expect(map.presentation.overlays.showsGrid && session.heatMap.isShown)
        #expect(map.presentation.overlays.mobAppearances["test:creature"] == MobAppearance(nil))
        map.setStyle(.waterDepth)
        session.visibility.showsTimeSpent = false
        #expect(resources.settings.mapPresentation(for: id).style == .waterDepth)
        #expect(!resources.settings.mapPresentation(for: id).overlays.showsTimeSpent)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func noDimensionDoesNotInventASavedRecordOrChangeTheFrontDimension() throws {
        let defaults = TestDefaults.make(), id = UUID(), key = "worldSettings." + id.uuidString
        defaults.set(["dimension": "test:front"], forKey: key)
        let settings = WorldSettings(id: id, defaults: defaults)
        var choices = settings.mapPresentation(for: nil)
        choices.overlays.showsGrid = true
        settings.save(choices, for: nil)
        #expect(settings.lastDimension == "test:front")
        #expect(defaults.dictionary(forKey: key)?["mapPresentations"] == nil)
    }
}
