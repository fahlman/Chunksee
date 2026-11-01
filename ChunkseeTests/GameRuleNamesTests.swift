import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct GameRuleNamesTests {
    @Test func gameMetadataNamesOldAndModernRulesInTheSelectedLanguage() async throws {
        let fixture = try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us",
                "gamerule.keepInventory": "Keep inventory", "gamerule.doDaylightCycle": "Advance time of day",
                "gamerule.doTraderSpawning": "Spawn Wandering Traders",
                "gamerule.test.custom.rule": "A supplied rule", "gamerule.oldRule": "A legacy rule"
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr", "gamerule.keepInventory": "Conserver l’inventaire"
            ]),
            "assets/minecraft/lang/deprecated.json": ItemPictureFixture.json([
                "removed": [], "renamed": [
                    "gamerule.keepInventory": "gamerule.minecraft.keep_inventory",
                    "gamerule.doDaylightCycle": "gamerule.minecraft.advance_time",
                    "gamerule.doTraderSpawning": "gamerule.minecraft.spawn_wandering_traders"
                ]
            ])
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        let names = GameNames(await library.data.language("fr_FR", minecraftDirectory: fixture.root))
        for id in ["keepInventory", "minecraft:keep_inventory", "keep_inventory", ":keep_inventory"] {
            #expect(names.gameRule(id) == "Conserver l’inventaire")
        }
        for id in ["doDaylightCycle", "minecraft:advance_time"] {
            #expect(names.gameRule(id) == "Advance time of day")
        }
        #expect(names.gameRule("doTraderSpawning") == "Spawn Wandering Traders")
        #expect(names.gameRule("minecraft:spawn_wandering_traders") == "Spawn Wandering Traders")
        #expect(names.gameRule("test:custom/rule") == "A supplied rule")
        #expect(names.gameRule("oldRule") == "A legacy rule")
        #expect(names.gameRule("test:future_rule") == "Future Rule")
        #expect(names.gameRule("futureRule") == "Future Rule")

        let rules: [String: GameRuleValue] = ["keepInventory": .bool(true), "minecraft:keep_inventory": .bool(false),
            "doTraderSpawning": .bool(false), "test:future_rule": .int(23)]
        let rows = names.gameRules(rules)
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) }) == rules)
        #expect(rows.map(\.name) == rows.map(\.name).sorted())
        #expect(rows.filter { $0.name == "Conserver l’inventaire" }.map(\.id) == ["keepInventory", "minecraft:keep_inventory"])
        #expect(GameRule.wanderingTraderSpawning.value(in: rules) == .bool(false))
        await library.close()
    }

    @Test func absentMappingsDoNotGuessAndReplacementChainsAreNotFollowed() async throws {
        let fixture = try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us", "gamerule.minecraft.advance_time": "Advance time of day",
                "gamerule.aRule": "The final destination", "gamerule.removedRule": "Removed text"
            ]),
            "assets/minecraft/lang/deprecated.json": ItemPictureFixture.json([
                "removed": ["gamerule.removedRule"], "renamed": [
                    "gamerule.aRule": "gamerule.bRule", "gamerule.bRule": "gamerule.cRule",
                    "gamerule.missingRule": "gamerule.missingDestination"
                ]
            ])
        ])
        defer { fixture.remove() }
        let library = try fixture.library()
        let names = GameNames(await library.data.language("en_US", minecraftDirectory: fixture.root))
        #expect(names.gameRule("minecraft:advance_time") == "Advance time of day")
        #expect(names.gameRule("doDaylightCycle") == "Do Daylight Cycle")
        #expect(names.gameRule("aRule") == "A Rule")
        #expect(names.gameRule("bRule") == "The final destination")
        #expect(names.gameRule("missingRule") == "Missing Rule")
        #expect(names.gameRule("removedRule") == "Removed Rule")
        await library.close()
    }

    @Test func noGameFilesKeepEverySavedRuleAndItsValue() {
        let rules: [String: GameRuleValue] = ["doDaylightCycle": .bool(false), "test:future_rule": .int(-7),
            "minecraft:keep_inventory": .bool(true)]
        let rows = GameNames.unavailable.gameRules(rules)
        #expect(rows.map(\.name) == ["Do Daylight Cycle", "Future Rule", "Keep Inventory"])
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) }) == rules)
    }
}
