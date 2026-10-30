import ChunkseeKitTestSupport
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
        return try #require(Creature(Fixtures.mob(fields)))
    }

    @Test func savedDefaultsComeFromKitAndUnnamedLevelsStayVisible() throws {
        let cases: [(Int32?, String)] = [(nil, "Farmer, Level 1"), (0, "Farmer, Level 0"), (6, "Farmer, Level 6")]
        for (level, expected) in cases {
            let saved = try creature(level: level)
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionContent(mobTypes: MobTypes([marker]))), players: [], gameNames: .unavailable) { _ in .named("") }
            #expect(villager.level == level.map(Int.init) ?? 1)
            #expect(marker.name(in: .unavailable) == "Farmer")
            #expect(hits.map { $0.title(in: .unavailable) } == ["Farmer"])
            #expect(GameNames.unavailable.profession(of: saved, definitions: nil) == expected)
        }
    }

    @Test func everyKnownLevelIsInTheInspectorAndItemNamesStayShort() throws {
        for (index, name) in ["Level 1", "Level 2", "Level 3", "Level 4", "Level 5"].enumerated() {
            let saved = try creature(level: Int32(index + 1))
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionContent(mobTypes: MobTypes([marker]))), players: [], gameNames: .unavailable) { _ in .named("") }
            #expect(hits.map { $0.title(in: .unavailable) } == ["Farmer"])
            #expect(GameNames.unavailable.profession(of: saved, definitions: nil) == "Farmer, \(name)")
            #expect(marker.name(in: .unavailable) == "Farmer")
        }
        var named = try creature(level: 2)
        named.customName = "Bob"
        #expect(CreatureMarker(named, dimension: "minecraft:overworld")?.name(in: .unavailable) == "Bob")
    }

    @Test func unemploymentKeepsTheGenericMarkerName() throws {
        for id in ["minecraft:none", "none", ":none", "", "invalid value"] {
            let saved = try creature(profession: id)
            let unemployed = try #require(saved.villager)
            #expect(GameNames.unavailable.profession(unemployed) == nil)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name(in: .unavailable) == "Villager")
        }
        for (id, name) in [("example:none", "None"), ("minecraft:nitwit", "Nitwit")] {
            let saved = try creature(profession: id)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name(in: .unavailable) == name)
        }
        let trader = try #require(Creature(Fixtures.mob([
            "id": .string("minecraft:wandering_trader"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
                "sell": .compound(["id": .string("minecraft:sand"), "count": .int(8)]),
            ])])]),
        ])))
        #expect(GameNames.unavailable.profession(of: trader, definitions: nil) == nil)
    }

    @Test func theInspectorDistinguishesUnknownProfessionsFromUnemployment() throws {
        let unknownProfessions: [String?] = [nil, "", "invalid value", "minecraft:"]
        for profession in unknownProfessions {
            #expect(GameNames.unavailable.profession(of: try creature(profession: profession), definitions: nil) == nil)
        }
        for profession in ["minecraft:none", "none", ":none"] {
            #expect(GameNames.unavailable.profession(of: try creature(profession: profession, offers: false), definitions: nil) == "None")
        }
        #expect(GameNames.unavailable.profession(of: try creature(profession: "minecraft:farmer", offers: false), definitions: nil) == "Farmer, Level 1")
        #expect(GameNames.unavailable.profession(of: try creature(level: 5, profession: "minecraft:nitwit", offers: false), definitions: nil) == "Nitwit")
        #expect(GameNames.unavailable.profession(of: try creature(profession: "example:none", offers: false), definitions: nil) == "None, Level 1")
        #expect(GameNames.unavailable.profession(of: try creature(profession: "example:beekeeper", offers: false), definitions: nil) == "Beekeeper, Level 1")
        // Explicit command-edited offers can trade even for an ordinarily nontrading profession.
        #expect(GameNames.unavailable.profession(of: try creature(profession: "minecraft:none"), definitions: nil) == "None, Level 1")
        #expect(GameNames.unavailable.profession(of: try creature(profession: "minecraft:nitwit"), definitions: nil) == "Nitwit, Level 1")
        #expect(GameNames.unavailable.profession(of: try creature(profession: "minecraft:none", kind: "minecraft:wandering_trader"), definitions: nil) == nil)
    }
}
