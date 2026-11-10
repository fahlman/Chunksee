import ChunkseeIndex
import Foundation
import CoreGraphics
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

/// The same valid legacy record at both endpoints; it exercises migration without touching
/// real preferences or relying on undecodable annotation bytes.
@MainActor
enum MapComparisonFixture {
    static let worldID = UUID(uuidString: "0F6EF86B-AF63-4DE6-97FA-15B174562A92")!
    static let playerID = UUID(uuidString: "82CD12B2-F080-4C19-83C3-10D828211BA7")!
    static let dimension = "minecraft:overworld"
    static let sibling = "minecraft:the_nether"
    static let key = "worldSettings." + worldID.uuidString
    static let places = Data(#"[{"id":"70CF5954-FFAE-4140-B114-85AE7494E4D7","name":"Comparison place","dimension":"minecraft:overworld","x":-31,"z":42}]"#.utf8)
    static let sections = ["views", "depths", "styles", "blockFilters", "lightingModes",
                           "castsShadows", "biomeBlending", "layers"]

    static var record: [String: Any] {
        [
            // The copied world has only the Overworld. A missing front dimension would
            // legitimately fall back on reopen, so retain an existing one and untouched sibling records.
            "dimension": dimension, "places": places, "shownVersionNotices": ["kept notice"],
            "views": [dimension: [-12.5, 33.0, 2.0], sibling: [7.0, 8.0, 4.0]],
            "depths": [dimension: ["y": -23, "surface": 0]],
            "styles": [dimension: "height"],
            "blockFilters": [dimension: ["enabled": false, "hidden": ["stone", "bad:id:bad"],
                                         "highlighted": ["sand", "stone"]] as [String: Any]],
            "lightingModes": [dimension: "daylight"], "castsShadows": [dimension: false],
            "biomeBlending": [dimension: true],
            "layers": [
                dimension: [
                    "structureVisibility": ["village": false, "mineshaft": true],
                    "shownPlaceGroups": ["spawner"], "shownCreatureGroups": ["pet"],
                    "shownMobTypes": ["minecraft:sheep"], "shownBiomeGroups": ["test:wetland"],
                    "hiddenPlayers": [playerID.uuidString, "invalid UUID"], "showsGrid": true,
                    "showsSavedPlaces": false, "showsWorldBorder": false,
                    "showsTimeSpent": true, "showsSlimeChunks": true, "showsDarkSpots": true,
                ] as [String: Any],
                sibling: ["showsGrid": false],
            ],
        ]
    }

    static func seed(_ defaults: UserDefaults) throws {
        let decoded = try JSONDecoder().decode([SavedPlace].self, from: places)
        try #require(decoded.count == 1 && decoded[0].name == "Comparison place")
        try #require(decoded[0].x == -31 && decoded[0].z == 42 && decoded[0].dimension == dimension)
        defaults.set(record, forKey: key)
    }

    static func capture(_ defaults: UserDefaults, settings: WorldSettings, to folder: URL) throws {
        let actual = try #require(defaults.dictionary(forKey: key))
        let bytes = try #require(actual["places"] as? Data)
        let decoded = try JSONDecoder().decode([SavedPlace].self, from: places)
        try #require(bytes == places && settings.savedPlaces == decoded)
        try #require(settings.lastDimension == dimension && settings.hasShownVersionNotice("kept notice"))
        for section in sections {
            let expected = (record[section] as? [String: Any])?[sibling]
            let retained = (actual[section] as? [String: Any])?[sibling]
            if let expected {
                try #require((retained as? NSObject)?.isEqual(expected) == true)
            } else {
                try #require(retained == nil)
            }
        }
        try MapComparisonEvidence.write([
            "raw-settings.plist": PropertyListSerialization.data(fromPropertyList: actual, format: .xml, options: 0),
            "annotation-bytes.json": bytes,
            "saved-places.json": MapComparisonEvidence.encoded(settings.savedPlaces),
        ], to: folder)
    }

    static func requireInitialChoices(_ session: WorldSession) throws {
        let map = try #require(session.map), layers = session.visibility
        try #require(map.chosenStyle == .height && map.depth == MapDepth(y: -23, isSurface: false))
        try #require(map.viewport == MapViewport(center: CGPoint(x: -12.5, y: 33), scale: 2))
        try #require(map.lightingMode == .daylight && !map.castsShadows && map.blendsBiomeColors)
        try #require(map.blockFilter == MapBlockFilter(isEnabled: false,
            hiddenIDs: ["minecraft:stone"], highlightedIDs: ["minecraft:sand"]))
        try #require(!layers.structures.contains(.village) && layers.structures.contains(.mineshaft))
        try #require(layers.places == [.spawner] && layers.creatures == [.pet])
        try #require(layers.mobTypes == ["minecraft:sheep"] && layers.biomes == [BiomeGroup(id: "test:wetland")])
        try #require(layers.hiddenPlayers == [playerID] && layers.showsGrid)
        try #require(!layers.showsSavedPlaces && !layers.showsWorldBorder)
        try #require(session.heatMap.isShown && session.slimeChunks.isShown && map.showsDarkSpots)
    }
}

