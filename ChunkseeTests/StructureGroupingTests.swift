import ChunkseeKit
import ChunkseeIndex
import Foundation
import Testing
@testable import ChunkseeTestHost

enum StructureTagFixture {
    static let members = [
        "village": ["minecraft:village_plains", "minecraft:village_savanna", "test:hill_fort"],
        "ocean_ruin": ["minecraft:ocean_ruin_cold"],
        "ruined_portal": ["test:broken_gateway"],
        "shipwreck": ["test:sunken_ship"],
        "mineshaft": ["minecraft:mineshaft_mesa"],
        "abandoned_camp": ["test:camp"],
    ]

    static func files(_ members: [String: [String]]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: members.map { name, values in
            ("data/minecraft/tags/worldgen/structure/\(name).json",
             try JSONSerialization.data(withJSONObject: ["values": values], options: .sortedKeys))
        })
    }

    static func catalog(_ contents: [String: [String]] = members) throws -> StructureGroup.Catalog {
        let fixture = try ItemPictureFixture(extraFiles: files(contents))
        defer { fixture.remove() }
        let assets = try #require(try GameAssets(contentsOf: fixture.jar))
        var tags: [String: GameTag] = [:]
        for id in StructureGroup.tagIDs { tags[id] = try assets.tag(id, in: "worldgen/structure") }
        return StructureGroup.Catalog(tags: tags)
    }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct StructureGroupingTests {
    @Test func tagMembersChooseFamiliesWithoutPrefixGuesses() throws {
        let groups = try StructureTagFixture.catalog()
        let expected: [String: StructureGroup] = [
            "minecraft:village_plains": .village, "test:hill_fort": .village,
            "minecraft:ocean_ruin_cold": .ruins, "test:broken_gateway": .ruinedPortal,
            "test:sunken_ship": .shipwreck, "minecraft:mineshaft_mesa": .mineshaft,
            "test:camp": .abandonedCamp, "minecraft:trail_ruins": .ruins,
            "minecraft:desert_pyramid": .temple, "minecraft:stronghold": .stronghold,
            "minecraft:village_unlisted": .other, "minecraft:shipwreck_unlisted": .other,
            "test:stronghold": .other, "test:unknown": .other,
        ]
        for (id, group) in expected { #expect(groups.group(for: id) == group) }
    }

    @Test func unavailableTagsPreserveVanillaGroupsButReadableEmptyTagsWin() throws {
        let withoutGame = StructureGroup.Catalog(tags: [:])
        let original: [String: StructureGroup] = ["village_plains": .village, "ocean_ruin_warm": .ruins,
            "ruined_portal_ocean": .ruinedPortal, "shipwreck_beached": .shipwreck, "mineshaft_mesa": .mineshaft]
        for (name, group) in original {
            #expect(withoutGame.group(for: "minecraft:" + name) == group)
            #expect(withoutGame.group(for: "test:" + name) == .other)
        }
        let partlyAvailable = try StructureTagFixture.catalog(["village": [], "shipwreck": ["test:boat"]])
        #expect(partlyAvailable.group(for: "minecraft:village_plains") == .other)
        #expect(partlyAvailable.group(for: "minecraft:shipwreck_beached") == .other)
        #expect(partlyAvailable.group(for: "test:boat") == .shipwreck)
        #expect(partlyAvailable.group(for: "minecraft:mineshaft_mesa") == .mineshaft)
        #expect(!partlyAvailable.group(for: "minecraft:mineshaft_mesa").isShownByDefault)
    }

    @Test func savedVisibilityKeepsChoicesAndGivesNewGroupsTheirDefaults() throws {
        let defaults = TestDefaults.make(), id = UUID(), dimension = "minecraft:overworld"
        let key = "worldSettings." + id.uuidString
        let settings = WorldSettings(id: id, defaults: defaults)
        var choices = MapPresentation()
        choices.overlays.structures = [.village, .mineshaft, .other, .abandonedCamp]
        settings.save(choices, for: dimension)
        var restored = WorldSettings(id: id, defaults: defaults).mapPresentation(for: dimension)
        #expect(restored.overlays.structures == choices.overlays.structures)
        restored.overlays.structures.remove(.abandonedCamp)
        restored.overlays.structures.insert(.stronghold)
        settings.save(restored, for: dimension)
        #expect(settings.mapPresentation(for: dimension).overlays.structures == [.village, .mineshaft, .other, .stronghold])
        #expect(settings.mapPresentation(for: "minecraft:the_nether").overlays.structures.contains(.abandonedCamp))

        let record = try JSONSerialization.data(withJSONObject: ["version": 1,
            "presentation": ["overlays": ["structures": ["village": false, "mineshaft": true]]]])
        defaults.set(["version": 2, "mapPresentations": [dimension: record]], forKey: key)
        let newer = settings.mapPresentation(for: dimension).overlays
        #expect(!newer.structures.contains(.village) && newer.structures.contains(.mineshaft))
        #expect(newer.structures.contains(.abandonedCamp) && !newer.structures.contains(.netherFossil))
    }

    @Test func livePackChangesReclassifyCachedStructuresWithoutLosingTheirIdentity() async throws {
        let ids = ["minecraft:village_plains", "test:hill_fort", "test:camp", "test:unknown"]
        var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var fields = try #require(chunk.nbt.compound)
        fields["structures"] = .compound(["starts": .compound(Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, NBT.compound(["id": .string(id), "ChunkX": .int(0), "ChunkZ": .int(0),
                "Children": .list([.compound(["id": .string("test:piece"),
                    "BB": .intArray([Int32(index * 3), 60, 0, Int32(index * 3 + 1), 70, 1])])])]))
        }))])
        chunk.nbt = .compound(fields)
        let root = try TestWorld.make(chunks: [chunk])
        let game = try ItemPictureFixture(extraFiles: StructureTagFixture.files([
            "village": ["minecraft:village_plains"], "abandoned_camp": ["test:camp"],
        ]))
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let tag = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/worldgen/structure/village.json")
        func write(_ json: String) throws {
            try FileManager.default.createDirectory(at: tag.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: tag, options: .atomic)
        }
        try write(#"{"replace":true,"values":["test:hill_fort"]}"#)
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root.appendingPathComponent("test-cache"),
            watchWorld: { _, _ in nil })
        resources.refreshDelay = .zero
        defer { resources.close() }
        func markers() async throws -> [StructureMarker] {
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            return try #require(resources.index.index.dimensions["minecraft:overworld"]).structures
        }
        func groups() async throws -> [String: StructureGroup] {
            Dictionary(uniqueKeysWithValues: try await markers().map { ($0.structureID, $0.group) })
        }
        let original = try await markers()
        #expect(try await groups() == ["minecraft:village_plains": .other, "test:hill_fort": .village,
                                      "test:camp": .other, "test:unknown": .other])
        resources.names.minecraft.choose(game.root)
        #expect(try await groups()["test:camp"] == .abandonedCamp)
        try write(#"{"values":["test:hill_fort"]}"#)
        resources.worldChanged([tag])
        #expect(try await groups() == ["minecraft:village_plains": .village, "test:hill_fort": .village,
                                      "test:camp": .abandonedCamp, "test:unknown": .other])
        let before = try #require(resources.readers["minecraft:overworld"])
        try write(#"{"replace":true,"values":["test:camp"]}"#)
        resources.worldChanged([tag])
        #expect(try await groups() == ["minecraft:village_plains": .other, "test:hill_fort": .other,
                                      "test:camp": .village, "test:unknown": .other])
        let after = try #require(resources.readers["minecraft:overworld"])
        #expect(before !== after && before.scanOptions == after.scanOptions)
        try write("malformed")
        resources.worldChanged([tag])
        #expect(try await groups()["test:camp"] == .abandonedCamp)
        #expect(try await groups()["test:hill_fort"] == .other)
        try FileManager.default.removeItem(at: tag)
        resources.worldChanged([tag])
        #expect(try await groups()["minecraft:village_plains"] == .village)
        resources.names.minecraft.forget()
        #expect(try await groups() == ["minecraft:village_plains": .village, "test:hill_fort": .other,
                                      "test:camp": .other, "test:unknown": .other])
        let hits = WorldSearch.search("structure:village", in: resources.index.index, players: [], gameNames: .unavailable) { _ in .named("") }
        #expect(hits.map { $0.title(in: .unavailable) } == ["Village Plains"])
        let refreshed = try await markers()
        #expect(refreshed.map(\.id) == original.map(\.id))
        #expect(refreshed.map(\.bounds) == original.map(\.bounds) && refreshed.map(\.y) == original.map(\.y))
        resources.close(); await resources.waitUntilClosed()
    }
}
