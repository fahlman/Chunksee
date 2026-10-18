import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct EnchantmentLabelTests {
    @Test func firstLevelsRemainVisibleInDecodedEquipmentAndTrades() throws {
        let item = try #require(ItemStack(.compound([
            "id": .string("minecraft:diamond_sword"), "count": .int(1),
            "components": .compound(["minecraft:enchantments": .compound([
                "minecraft:sharpness": .int(1), "minecraft:unbreaking": .int(1),
            ])]),
        ])))
        #expect(TradeText.describe(item) == "1 Diamond Sword (Sharpness I, Unbreaking I)")
        #expect(ItemAppearance.details(of: item).contains("Sharpness I\nUnbreaking I"))
        let legacy = try #require(ItemStack(.compound([
            "id": .string("minecraft:enchanted_book"), "Count": .byte(1),
            "tag": .compound(["StoredEnchantments": .list([.compound([
                "id": .string("minecraft:protection"), "lvl": .short(1),
            ])])]),
        ])))
        #expect(TradeText.describe(legacy) == "1 Enchanted Book (Protection I)")
    }

    @Test func onlyVerifiedSingleLevelVanillaEnchantmentsHideOne() {
        let names = ["aqua_affinity", "binding_curse", "channeling", "flame", "infinity",
                     "mending", "multishot", "silk_touch", "vanishing_curse"]
        for name in names {
            #expect(TradeText.enchantmentName("minecraft:" + name, level: 1) == ReadableName.from(name))
            #expect(TradeText.enchantmentName("minecraft:" + name, level: 2) == ReadableName.from(name) + " II")
            #expect(TradeText.enchantmentName("example:" + name, level: 1) == ReadableName.from(name) + " I")
        }
        #expect(TradeText.enchantmentName("example:new_enchantment", level: 1) == "New Enchantment I")
        #expect(TradeText.enchantmentName("minecraft:lunge", level: 1) == "Lunge I")
        #expect(TradeText.enchantmentName("minecraft:sharpness", level: 0) == "Sharpness 0")
        #expect(TradeText.enchantmentName("minecraft:sharpness", level: 11) == "Sharpness 11")
        #expect(PlayerEffectText.name(StatusEffect(id: "minecraft:strength", amplifier: 0, durationTicks: 20)) == "Strength")
    }
}
