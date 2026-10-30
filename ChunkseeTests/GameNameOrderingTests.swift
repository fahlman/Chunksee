import ChunkseeIndex
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct GameNameOrderingTests {
    @Test func translatedCollectionsUseNaturalNameOrderAndStableSavedIDs() async throws {
        let samples = [("en_us", "Rule 2", "Rule 10"), ("fr_fr", "Événements", "Vérification"),
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
        }
        await library.close()
    }
}
