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

    static func catalog() throws -> StructureGroup.Catalog {
        let fixture = try ItemPictureFixture(extraFiles: files(members))
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
        #expect(StructureGroup.Catalog(tags: [:]).group(for: "minecraft:village_plains") == .other)
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
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
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
        #expect(try await groups().values.allSatisfy { $0 == .other })
        let refreshed = try await markers()
        #expect(refreshed.map(\.id) == original.map(\.id))
        #expect(refreshed.map(\.bounds) == original.map(\.bounds) && refreshed.map(\.y) == original.map(\.y))
        resources.close(); await resources.waitUntilClosed()
    }
}
