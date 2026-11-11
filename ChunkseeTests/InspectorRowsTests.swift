import ChunkseeKitTestSupport
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct InspectorRowsTests {
    private let english = Locale(identifier: "en_US")

    @Test func savedPetAndPlayerHealthHaveTheSamePrecisionAndGauge() throws {
        let attributes = NBT.list([.compound(["id": .string("minecraft:max_health"), "base": .double(40)])])
        var nbt = pet("minecraft:wolf").compound!
        nbt["Health"] = .float(19.5)
        nbt["attributes"] = attributes
        let creature = try #require(Creature(Fixtures.mob(nbt), dataVersion: 5023))
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "Health": .float(19.5), "attributes": attributes,
        ]))
        let animal = HealthPresentation(health: creature.health, maximum: creature.maxHealth)
        let person = HealthPresentation(health: player.health, maximum: player.maxHealth)
        #expect(animal == person)
        #expect(animal.text(locale: english) == "9.75 of 20 hearts")
        #expect(animal.gaugeValue == 19.5 && animal.maximum == 40)
        #expect(person.text(locale: Locale(identifier: "fr_FR")) == "9,75 of 20 hearts")
    }

    @Test func missingOrInvalidHealthNeverCreatesAnInventedGauge() {
        let cases: [(Double?, Double?, String?, Double?)] = [
            (19.5, nil, "9.75 hearts", nil), (nil, 40, "20 hearts", nil),
            (19.5, 0, "9.75 hearts", nil), (0, 40, "0 of 20 hearts", 0),
            (42, 40, "21 of 20 hearts", 40), (.nan, 40, "20 hearts", nil),
            (19.5, .infinity, "9.75 hearts", nil), (-1, nil, nil, nil), (nil, nil, nil, nil),
        ]
        for (health, maximum, text, gauge) in cases {
            let reading = HealthPresentation(health: health, maximum: maximum)
            #expect(reading.text(locale: english) == text)
            #expect(reading.gaugeValue == gauge)
            #expect(reading.isAvailable == (text != nil))
        }
        #expect(HealthPresentation.hearts(0.5, locale: english) == "0.25 hearts")
        #expect(HealthPresentation.hearts(.infinity, locale: english) == nil)
    }

    @Test func decodedEquipmentRetainsKindNameWearAndSelectedHandInSharedRows() throws {
        let armor = item("minecraft:wolf_armor", name: "Fluffy Coat", wear: true)
        var nbt = pet("minecraft:wolf").compound!
        nbt["equipment"] = .compound(["body": armor])
        let wolf = try #require(Creature(Fixtures.mob(nbt), dataVersion: 5023))
        let rows = EquipmentPresentation.rows(try #require(wolf.equipment))
        let coat = try #require(rows.first?.item)
        #expect(rows.map(\.slot) == ["body"])
        #expect(rows.map { GameNames.unavailable.equipmentSlot($0.slot) } == ["Body"])
        #expect(GameNames.unavailable.itemName(of: coat) == "Wolf Armor “Fluffy Coat”")
        #expect(ItemAppearance.symbol(for: coat.id) == "tshirt.fill")
        #expect(coat.durability == ItemDurability(remaining: 97, maximum: 100))
        #expect(GameNames.unavailable.itemDetails(of: coat).contains(ItemAppearance.durability(try #require(coat.durability))))
        #expect(GameNames.unavailable.itemDetails(of: coat).contains("Unbreaking III"))

        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "SelectedItemSlot": .int(2),
            "Inventory": .list([item("minecraft:stone_axe", slot: 0), item("minecraft:iron_pickaxe", name: "Miner", slot: 2, wear: true)]),
            "equipment": .compound([
                "head": item("minecraft:golden_helmet", name: "Aurum", wear: true),
                "offhand": item("minecraft:torch", count: 64), "chest": item("minecraft:iron_chestplate", count: 0),
                "unknown": item("minecraft:apple"), "storage": item("minecraft:chest"),
                "custom:extra": item("minecraft:diamond"),
            ]),
        ]))
        let equipped = EquipmentPresentation.rows(player.equippedItems)
        #expect(equipped.map(\.slot) == ["head", "mainhand", "offhand", "storage", "custom:extra", "unknown"])
        #expect(equipped.map { GameNames.unavailable.equipmentSlot($0.slot) } == ["Head", "Main Hand", "Off Hand", "Storage", "Extra", "Unknown"])
        #expect(equipped.map { GameNames.unavailable.itemName(of: $0.item) } == ["Golden Helmet “Aurum”", "Iron Pickaxe “Miner”", "64 Torch", "Chest", "Diamond", "Apple"])
        #expect(EquipmentPresentation.rows(["body": ItemStack(id: "minecraft:wolf_armor", count: 0)]).isEmpty)
        #expect(ItemAppearance.durability(.init(remaining: 1500, maximum: 1561), locale: english) == "Durability: 1,500 of 1,561")
    }

    @Test func onlyAvailableAnimalEquipmentIsPresented() throws {
        var donkeyNBT = pet("minecraft:donkey").compound!
        donkeyNBT["ChestedHorse"] = .byte(1)
        donkeyNBT["equipment"] = .compound(["saddle": item("minecraft:saddle")])
        let donkey = try #require(Creature(Fixtures.mob(donkeyNBT), dataVersion: 5023))
        let carried = EquipmentPresentation.rows(try #require(donkey.equipment))
        #expect(carried.map(\.slot) == ["saddle", "storage"])
        #expect(carried.map { GameNames.unavailable.equipmentSlot($0.slot) } == ["Saddle", "Storage"])
        #expect(carried.map { $0.item.id } == ["minecraft:saddle", "minecraft:chest"])
        let wolf = try #require(Creature(pet("minecraft:wolf"), dataVersion: 5023))
        #expect(try #require(wolf.equipment).isEmpty)
        let parrot = try #require(Creature(pet("minecraft:parrot"), dataVersion: 5023))
        #expect(try #require(parrot.equipment).isEmpty)
    }

    private func pet(_ id: String) -> NBT {
        Fixtures.mob(["id": .string(id), "Health": .float(20), "Owner": .intArray([1, 2, 3, 4]),
                   "Pos": .list([.double(0), .double(64), .double(0)])])
    }

    private func item(_ id: String, name: String? = nil, count: Int32 = 1, slot: Int8? = nil, wear: Bool = false) -> NBT {
        var fields: [String: NBT] = ["id": .string(id), "count": .int(count)]
        if let slot { fields["Slot"] = .byte(slot) }
        var components: [String: NBT] = [:]
        if let name { components["minecraft:custom_name"] = .string(name) }
        if wear {
            components["minecraft:max_damage"] = .int(100)
            components["minecraft:damage"] = .int(3)
            components["minecraft:enchantments"] = .compound(["minecraft:unbreaking": .int(3)])
        }
        fields["components"] = .compound(components)
        return .compound(fields)
    }
}
