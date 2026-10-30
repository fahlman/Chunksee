import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@MainActor enum EnchantmentNameFixture {
    static let literal = #"{"text":"Literal pack name"}"#

    static func game(ward: String = "Warding", maximumLevel: Int = 3) throws -> ItemPictureFixture {
        func definition(_ description: Any, maximum: Int) throws -> Data {
            try ItemPictureFixture.json(["description": description, "max_level": maximum, "slots": ["any"], "effects": [:]])
        }
        return try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us", "pack.words.guard": ward,
                "enchantment.minecraft.mending": "Mending", "enchantment.level.1": "I", "enchantment.level.2": "II",
                "item.minecraft.diamond_sword": "Diamond Sword", "item.minecraft.enchanted_book": "Enchanted Book",
                "item.test.token": "Trade Token", "block.test.box": "Pack Box",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr", "pack.words.guard": "Garde", "item.test.token": "Jeton",
            ]),
            "data/minecraft/enchantment/mending.json": definition(["translate": "enchantment.minecraft.mending"], maximum: 1),
            "data/test/enchantment/ward.json": definition(["translate": "pack.words.guard"], maximum: maximumLevel),
            "data/test/enchantment/literal.json": definition(["text": literal], maximum: 1),
            "data/test/enchantment/dynamic.json": definition(["selector": "@s"], maximum: 1),
            "data/test/enchantment/absent_description.json": ItemPictureFixture.json([
                "max_level": 1, "slots": ["any"], "effects": [:],
            ]),
        ])
    }

    static func names(_ locale: String = "en_US", maximumLevel: Int = 3) async throws -> GameNames {
        let game = try game(maximumLevel: maximumLevel), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let assets = try #require(try GameAssets(contentsOf: game.jar))
        let definitions = try World(contentsOf: root).enchantmentDefinitions(assets: assets)
        let language = await (try game.library()).data.language(locale, minecraftDirectory: game.root)
        return GameNames(language).withEnchantments(GameNames.Enchantments(definitions))
    }
}

@Suite(.isolatedStores) struct EnchantmentLabelTests {
    @Test func firstLevelsRemainVisibleInDecodedEquipmentAndTrades() throws {
        let item = try #require(ItemStack(.compound([
            "id": .string("minecraft:diamond_sword"), "count": .int(1),
            "components": .compound(["minecraft:enchantments": .compound([
                "minecraft:sharpness": .int(1), "minecraft:unbreaking": .int(1),
            ])]),
        ])))
        #expect(GameNames.unavailable.tradeDescription(item) == "1 Diamond Sword (Sharpness I, Unbreaking I)")
        #expect(GameNames.unavailable.itemDetails(of: item).contains("Sharpness I\nUnbreaking I"))
        let legacy = try #require(ItemStack(.compound([
            "id": .string("minecraft:enchanted_book"), "Count": .byte(1),
            "tag": .compound(["StoredEnchantments": .list([.compound([
                "id": .string("minecraft:protection"), "lvl": .short(1),
            ])])]),
        ])))
        #expect(GameNames.unavailable.tradeDescription(legacy) == "1 Enchanted Book (Protection I)")
    }

    @Test func actualDefinitionsSupplyDescriptionsAndDecideWhetherToShowOne() async throws {
        let names = try await EnchantmentNameFixture.names()
        #expect(names.enchantmentName("minecraft:mending", level: 1) == "Mending")
        #expect(names.enchantmentName("minecraft:mending", level: 2) == "Mending II")
        #expect(names.enchantmentName("test:ward", level: 1) == "Warding I")
        #expect(names.enchantmentName("test:literal", level: 1) == EnchantmentNameFixture.literal)
        #expect(names.enchantmentName("test:literal", level: 2) == EnchantmentNameFixture.literal + " II")
        #expect(names.enchantmentName("test:dynamic", level: 1) == "Dynamic")
        #expect(names.enchantmentName("test:absent_description", level: 1) == "Absent Description")
        #expect(names.enchantmentName("example:mending", level: 1) == "Mending I")
        #expect(names.enchantmentName("minecraft:flame", level: 1) == "Flame I")
        #expect(names.enchantmentName("minecraft:sharpness", level: 0) == "Sharpness 0")
        #expect(names.enchantmentName("minecraft:sharpness", level: 11) == "Sharpness 11")
        #expect(GameNames.unavailable.enchantmentName("minecraft:mending", level: 1) == "Mending I")
        let changed = try await EnchantmentNameFixture.names(maximumLevel: 1)
        #expect(changed.enchantmentName("test:ward", level: 1) == "Warding")
        #expect(names.enchantmentName("test:ward", level: 1) == "Warding I")
    }

    @Test func descriptionTranslationUsesTheSelectedLanguageThenEnglish() async throws {
        let names = try await EnchantmentNameFixture.names("fr_FR")
        for locale in ["en_US", "fr_FR", "ar_EG"].map(Locale.init(identifier:)) {
            #expect(names.enchantmentName("test:ward", level: 1, locale: locale) == "Garde I")
            #expect(names.enchantmentName("minecraft:mending", level: 1, locale: locale) == "Mending")
            #expect(names.enchantmentName("example:mending", level: 1, locale: locale) == "Mending I")
        }
    }
}
