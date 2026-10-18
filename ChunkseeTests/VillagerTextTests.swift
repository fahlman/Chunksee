import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct VillagerTextTests {
    func creature(level: Int32? = nil, job: String = "minecraft:farmer") throws -> Creature {
        var data: [String: NBT] = ["profession": .string(job)]
        if let level { data["level"] = .int(level) }
        return try #require(Creature(.compound([
            "id": .string("minecraft:villager"), "Health": .float(20),
            "Pos": .list([.double(2), .double(64), .double(3)]), "VillagerData": .compound(data),
            "Offers": .compound(["Recipes": .list([.compound([
                "buy": .compound(["id": .string("minecraft:wheat"), "count": .int(20)]),
                "sell": .compound(["id": .string("minecraft:emerald"), "count": .int(1)]),
            ])])]),
        ])))
    }

    @Test func missingAndUnknownLevelsAreNotCalledNovice() throws {
        let levels: [Int32?] = [nil, 0, 6]
        for level in levels {
            let saved = try creature(level: level)
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creatures: [marker])), players: []) { _ in "" }
            #expect(VillagerText.description(villager) == "Farmer")
            #expect(marker.name == "Farmer")
            #expect(hits.map(\.title) == ["Farmer"])
        }
    }

    @Test func everyKnownLevelIsConsistentAndShortMarkersStayShort() throws {
        for (index, name) in ["Novice", "Apprentice", "Journeyman", "Expert", "Master"].enumerated() {
            let saved = try creature(level: Int32(index + 1))
            let villager = try #require(saved.villager)
            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let hits = WorldSearch.search("trade:emerald", in: .overworld(DimensionIndex(creatures: [marker])), players: []) { _ in "" }
            #expect(VillagerText.description(villager) == "Farmer, \(name)")
            #expect(hits.map(\.title) == ["Farmer, \(name)"])
            #expect(marker.name == "Farmer")
        }
        var named = try creature(level: 2)
        named.customName = "Bob"
        #expect(CreatureMarker(named, dimension: "minecraft:overworld")?.name == "Bob")
    }

    @Test func noJobIsNotShownAsAnOccupation() throws {
        let unemployed = try #require(creature(job: "minecraft:none").villager)
        #expect(VillagerText.jobName(unemployed) == nil)
        #expect(VillagerText.description(unemployed) == nil)
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
}
