import ChunkseeIndex
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameNameOrderingTests {
    @Test func translatedCollectionsUseNaturalNameOrderAndStableSavedIDs() async throws {
        let samples = [("en_us", "Rule 2", "Rule 10"), ("fr_fr", "Âne", "Loup"),
                       ("de_de", "Überfälle", "Zucker"), ("pl_pl", "Łup", "Zmniejszone"),
                       ("tr_tr", "Ölüm", "Zaman")]
        var files: [String: Data] = [:]
        for (language, first, last) in samples {
            var strings = ["language.code": language]
            for registry in ["gamerule", "block", "biome", "entity", "item"] {
                strings["\(registry).test.a"] = first
                strings["\(registry).test.b"] = first
                strings["\(registry).test.z"] = last
                strings["\(registry).test.more"] = last
            }
            strings["entity.minecraft.cat"] = first
            strings["entity.minecraft.wolf"] = last
            files["assets/minecraft/lang/\(language).json"] = try ItemPictureFixture.json(strings)
        }
        let fixture = try ItemPictureFixture(extraFiles: files)
        defer { fixture.remove() }
        let library = try fixture.library()
        let ids = ["test:a", "test:b", "test:z"]
        let rules: [String: GameRuleValue] = ["test:a": .bool(true), "test:b": .bool(false), "test:z": .int(7)]
        let mobs = try MobTypes(ids.enumerated().map { index, id in
            try #require(CreatureMarker(Creature(id: id, x: Double(index), y: 64, z: 0),
                                        dimension: "minecraft:overworld"))
        })
        let containers = ItemContainer.containers(inChunk: .compound(["block_entities": .list([
            .compound(["id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
                "Items": .list(ids.map { ItemLabelTests().item($0, count: 3) }
                    + [ItemLabelTests().item("test:more", count: 6)])]),
        ])]))
        let totals = StoredItemTotal.totals(in: containers)
        let root = try linkedPetWorld()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), players = PlayerNames(defaults: defaults)
        players.minecraft.choose(fixture.root)
        let world = try await WorldResources(snapshot: WorldSnapshot.read(root), names: players,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let session = WorldSession(resources: world)
        defer { session.close() }
        await session.search.waitForIndex()
        let owner = try #require(UUID(uuidString: "0000000a-0000-0014-0000-001e00000028"))
        let original = session.presentation.linkedPets(to: owner)
        #expect(original.count == 5)
        for (language, first, last) in samples {
            let names = GameNames(await library.data.language(language, minecraftDirectory: fixture.root))
            let rows = names.gameRules(rules)
            #expect(rows.map(\.name) == [first, first, last])
            #expect(rows.map(\.id) == ids)
            #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) }) == rules)
            #expect(names.blockIDs(in: Set(ids), matching: "") == ids)
            #expect(names.layerGroups(Set(ids.map { BiomeGroup(id: $0) })).map(\.id) == ids)
            #expect(names.mobKinds(in: mobs).map(\.id) == ids)
            let stored = names.storedItems(totals)
            #expect(stored.map(\.id) == ["test:more"] + ids)
            #expect(stored.map(\.count) == [6, 3, 3, 3])
            #expect(stored.allSatisfy { $0.containers == 1 })
            let summary = try #require(WorldSearch.summary(of: containers.flatMap(\.items), query: SearchQuery("test:"), gameNames: names))
            #expect(summary.items.map(\.id) == ["test:more"] + ids)
            #expect(summary.items.map(\.count) == [6, 3, 3, 3] && summary.count == 15)
            let custom = try #require(WorldSearch.summary(of: [
                ItemStack(id: "test:z", count: 3, customName: last),
                ItemStack(id: "test:z", count: 3, customName: first)
            ], query: SearchQuery("test:"), gameNames: names))
            #expect(custom.items.map(\.name.customName) == [first, last])
            #expect(custom.items.map(\.count) == [3, 3] && custom.count == 6)

            world.refreshGameLanguage(preferredLanguage: language)
            await world.waitForRefresh()
            let linked = session.presentation.linkedPets(to: owner)
            #expect(linked.map { $0.creature.x } == [1, 2, 3, 4, 5])
            #expect(linked.map(\.dimension) == Array(repeating: "minecraft:overworld", count: 3)
                    + Array(repeating: "minecraft:the_nether", count: 2))
            #expect(linked.map { world.gameNames.creature($0.creature) } == [first, first, last, "Pet 2", "Pet 10"])
            #expect(Set(linked.map(\.id)) == Set(original.map(\.id)))
            #expect(linked.map { $0.creature.y } == Array(repeating: 64, count: 5))
        }
        session.close(); await session.waitUntilClosed()
        await library.close()
    }

    private func linkedPetWorld() throws -> URL {
        let root = try TestWorld.make(chunks: [])
        func entity(_ id: String, number: Int32, owner: [Int32]?, name: String? = nil) -> NBT {
            var fields: [String: NBT] = ["id": .string(id), "UUID": .intArray([1, 2, 3, number]),
                "Pos": .list([.double(Double(number)), .double(64), .double(0)])]
            if let owner { fields["Owner"] = .intArray(owner) }
            if let name { fields["CustomName"] = .string(name) }
            return Fixtures.mob(fields)
        }
        let owner: [Int32] = [10, 20, 30, 40]
        let dimensions: [(String, [NBT])] = [
            ("overworld", [entity("minecraft:wolf", number: 3, owner: owner),
                           entity("minecraft:cat", number: 2, owner: owner),
                           entity("minecraft:cat", number: 1, owner: owner),
                           entity("minecraft:cat", number: 6, owner: [50, 60, 70, 80]),
                           entity("minecraft:cat", number: 7, owner: nil)]),
            ("the_nether", [entity("minecraft:cat", number: 5, owner: owner, name: "Pet 10"),
                            entity("minecraft:cat", number: 4, owner: owner, name: "Pet 2")])
        ]
        for (dimension, entities) in dimensions {
            let folder = root.appendingPathComponent("dimensions/minecraft/\(dimension)")
            for child in ["region", "entities"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(child), withIntermediateDirectories: true)
            }
            let chunk = NBT.compound(["DataVersion": .int(Int32(5023)),
                                     "Position": .intArray([0, 0]), "Entities": .list(entities)])
            try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: chunk)]))
                .write(to: folder.appendingPathComponent("entities/r.0.0.mca"))
        }
        return root
    }
}
