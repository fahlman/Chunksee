import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DurabilityPresentationTests {
    @Test func damagedItemsUseMinecraftBarStepsAndHue() throws {
        // Include the half-pixel boundary and a damaged item whose bar still rounds to full width.
        let cases: [(damage: Int32, maximum: Int32, pixels: Int, hue: Double)] = [
            (1, 100, 13, 0.33), (13, 26, 7, 1.0 / 6), (25, 26, 1, 1.0 / 78),
            (249, 250, 0, 1.0 / 750), (250, 250, 0, 0),
        ]
        for sample in cases {
            let item = ItemStack(id: "minecraft:iron_pickaxe", components: .compound([
                "minecraft:damage": .int(sample.damage), "minecraft:max_damage": .int(sample.maximum),
            ]))
            let reading = try #require(DurabilityPresentation(item.durability))
            #expect(reading.isDamaged)
            #expect(reading.barPixels == sample.pixels)
            #expect(abs(reading.hue - sample.hue) < 0.000001)
            #expect(reading.wear.remaining == Int(sample.maximum - sample.damage))
        }
    }

    @Test func onlyDamagedDurableItemsHaveInventoryBars() throws {
        let newPickaxe = try #require(DurabilityPresentation(ItemStack(id: "minecraft:iron_pickaxe").durability))
        #expect(!newPickaxe.isDamaged)
        #expect(newPickaxe.wear == ItemDurability(remaining: 250, maximum: 250))
        let unbreakable = ItemStack(id: "minecraft:iron_pickaxe", components: .compound([
            "minecraft:damage": .int(100), "minecraft:unbreakable": .compound([:]),
        ]))
        #expect(DurabilityPresentation(unbreakable.durability) == nil)
        #expect(DurabilityPresentation(ItemStack(id: "minecraft:apple").durability) == nil)
        #expect(DurabilityPresentation(nil) == nil)
    }

    @Test func invalidDurabilityCannotCreateAnInvalidGauge() {
        for wear in [ItemDurability(remaining: 0, maximum: 0), .init(remaining: 1, maximum: -1),
                     .init(remaining: -1, maximum: 250), .init(remaining: 251, maximum: 250)] {
            #expect(DurabilityPresentation(wear) == nil)
        }
    }

    @Test func gaugeAndTooltipKeepLocalizedDurabilityAmounts() {
        let wear = ItemDurability(remaining: 1500, maximum: 1561)
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        #expect(ItemAppearance.durability(wear, includingLabel: false, locale: english) == "1,500 of 1,561")
        #expect(ItemAppearance.durability(wear, locale: english) == "Durability: 1,500 of 1,561")
        #expect(ItemAppearance.durability(wear, includingLabel: false, locale: german) == "1.500 of 1.561")
        #expect(ItemAppearance.durability(wear, locale: german) == "Durability: 1.500 of 1.561")
    }
}
