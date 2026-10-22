import ChunkseeIndex
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct VillagerTextTests {
    func creature(level: Int32? = nil, profession: String? = "minecraft:farmer",
                  kind: String = "minecraft:villager", offers: Bool = true) throws -> Creature {
        var data: [String: NBT] = [:]
        if let profession { data["profession"] = .string(profession) }
        if let level { data["level"] = .int(level) }
        var fields: [String: NBT] = [
            "id": .string(kind), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]), "VillagerData": .compound(data),
        ]
        if offers {
            fields["Offers"] = .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:wheat"), "count": .int(20)]),
                "sell": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
            ])])])
        }
        return try #require(Creature(.compound(fields)))
    }

    @Test func savedDefaultsComeFromKitAndUnknownLevelsStayAbsent() throws {
        let cases: [(Int32?, String)] = [(nil, "Farmer, Novice"), (0, "Farmer"), (6, "Farmer")]
        for (level, expected) in cases {
            let saved = try creature(level: level)
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creaturePoints: PointMarkers([marker]))), players: []) { _ in .named("") }
            #expect(villager.level == level.map(Int.init) ?? 1)
            #expect(marker.name == "Farmer")
            #expect(hits.map(\.title) == ["Farmer"])
            #expect(VillagerText.inspectorProfession(saved) == expected)
        }
    }

    @Test func everyKnownLevelIsInTheInspectorAndItemNamesStayShort() throws {
        for (index, name) in ["Novice", "Apprentice", "Journeyman", "Expert", "Master"].enumerated() {
            let saved = try creature(level: Int32(index + 1))
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creaturePoints: PointMarkers([marker]))), players: []) { _ in .named("") }
            #expect(hits.map(\.title) == ["Farmer"])
            #expect(VillagerText.inspectorProfession(saved) == "Farmer, \(name)")
            #expect(marker.name == "Farmer")
        }
        var named = try creature(level: 2)
        named.customName = "Bob"
        #expect(CreatureMarker(named, dimension: "minecraft:overworld")?.name == "Bob")
    }

    @Test func unemploymentKeepsTheGenericMarkerName() throws {
        for id in ["minecraft:none", "none", ":none", "", "invalid value"] {
            let saved = try creature(profession: id)
            let unemployed = try #require(saved.villager)
            #expect(VillagerText.professionName(unemployed) == nil)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name == "Villager")
        }
        for (id, name) in [("example:none", "None"), ("minecraft:nitwit", "Nitwit")] {
            let saved = try creature(profession: id)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name == name)
        }
        let trader = try #require(Creature(.compound([
            "id": .string("minecraft:wandering_trader"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
                "sell": .compound(["id": .string("minecraft:sand"), "count": .int(8)]),
            ])])]),
        ])))
        #expect(VillagerText.inspectorProfession(trader) == nil)
    }

    @Test func theInspectorDistinguishesUnknownProfessionsFromUnemployment() throws {
        let unknownProfessions: [String?] = [nil, "", "invalid value", "minecraft:"]
        for profession in unknownProfessions {
            #expect(VillagerText.inspectorProfession(try creature(profession: profession)) == nil)
        }
        for profession in ["minecraft:none", "none", ":none"] {
            #expect(VillagerText.inspectorProfession(try creature(profession: profession, offers: false)) == "None")
        }
        #expect(VillagerText.inspectorProfession(try creature(profession: "minecraft:farmer", offers: false)) == "Farmer, Novice")
        #expect(VillagerText.inspectorProfession(try creature(level: 5, profession: "minecraft:nitwit", offers: false)) == "Nitwit")
        #expect(VillagerText.inspectorProfession(try creature(profession: "example:none", offers: false)) == "None, Novice")
        #expect(VillagerText.inspectorProfession(try creature(profession: "example:beekeeper", offers: false)) == "Beekeeper, Novice")
        // Explicit command-edited offers can trade even for an ordinarily nontrading profession.
        #expect(VillagerText.inspectorProfession(try creature(profession: "minecraft:none")) == "None, Novice")
        #expect(VillagerText.inspectorProfession(try creature(profession: "minecraft:nitwit")) == "Nitwit, Novice")
        #expect(VillagerText.inspectorProfession(try creature(profession: "minecraft:none", kind: "minecraft:wandering_trader")) == nil)
    }
}
