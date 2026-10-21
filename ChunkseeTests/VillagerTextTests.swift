import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct VillagerTextTests {
    func creature(level: Int32? = nil, job: String? = "minecraft:farmer", kind: String = "minecraft:villager") throws -> Creature {
        var data: [String: NBT] = [:]
        if let job { data["profession"] = .string(job) }
        if let level { data["level"] = .int(level) }
        return try #require(Creature(.compound([
            "id": .string(kind), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]), "VillagerData": .compound(data),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:wheat"), "count": .int(20)]),
                "sell": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
            ])])]),
        ])))
    }

    @Test func savedDefaultsComeFromKitAndUnknownLevelsStayAbsent() throws {
        let cases: [(Int32?, String)] = [(nil, "Farmer, Novice"), (0, "Farmer"), (6, "Farmer")]
        for (level, expected) in cases {
            let saved = try creature(level: level)
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creaturePoints: PointMarkers([marker]))), players: []) { _ in .named("") }
            #expect(villager.level == level.map(Int.init) ?? 1)
            #expect(VillagerText.description(villager) == expected)
            #expect(marker.name == "Farmer")
            #expect(hits.map(\.title) == ["Farmer"])
            #expect(VillagerText.inspectorJob(saved) == expected)
        }
    }

    @Test func everyKnownLevelIsInTheInspectorAndItemNamesStayShort() throws {
        for (index, name) in ["Novice", "Apprentice", "Journeyman", "Expert", "Master"].enumerated() {
            let saved = try creature(level: Int32(index + 1))
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creaturePoints: PointMarkers([marker]))), players: []) { _ in .named("") }
            #expect(VillagerText.description(villager) == "Farmer, \(name)")
            #expect(hits.map(\.title) == ["Farmer"])
            #expect(VillagerText.inspectorJob(saved) == "Farmer, \(name)")
            #expect(marker.name == "Farmer")
        }
        var named = try creature(level: 2)
        named.customName = "Bob"
        #expect(CreatureMarker(named, dimension: "minecraft:overworld")?.name == "Bob")
    }

    @Test func noJobIsNotShownAsAnOccupation() throws {
        for id in ["minecraft:none", "none", ":none", "", "invalid value"] {
            let saved = try creature(job: id)
            let unemployed = try #require(saved.villager)
            #expect(VillagerText.jobName(unemployed) == nil)
            #expect(VillagerText.description(unemployed) == nil)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name == "Villager")
        }
        for (id, name) in [("example:none", "None"), ("minecraft:nitwit", "Nitwit")] {
            let saved = try creature(job: id)
            #expect(CreatureMarker(saved, dimension: "minecraft:overworld")?.name == name)
        }
        let trader = try #require(Creature(.compound([
            "id": .string("minecraft:wandering_trader"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
                "sell": .compound(["id": .string("minecraft:sand"), "count": .int(8)]),
            ])])]),
        ]))?.villager)
        #expect(VillagerText.description(trader) == nil)
    }

    @Test func theInspectorDistinguishesAnUnknownJobFromUnemployment() throws {
        let unknownJobs: [String?] = [nil, "", "invalid value", "minecraft:"]
        for job in unknownJobs {
            #expect(VillagerText.inspectorJob(try creature(job: job)) == nil)
        }
        for job in ["minecraft:none", "none", ":none"] {
            #expect(VillagerText.inspectorJob(try creature(job: job)) == "None")
        }
        #expect(VillagerText.inspectorJob(try creature(job: "minecraft:farmer")) == "Farmer, Novice")
        #expect(VillagerText.inspectorJob(try creature(job: "minecraft:nitwit")) == "Nitwit, Novice")
        #expect(VillagerText.inspectorJob(try creature(job: "example:none")) == "None, Novice")
        #expect(VillagerText.inspectorJob(try creature(job: "minecraft:none", kind: "minecraft:wandering_trader")) == nil)
    }
}
