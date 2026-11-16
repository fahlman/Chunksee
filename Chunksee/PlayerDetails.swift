import ChunkseeKit
import SwiftUI

/// Shared item wording and fallback symbols/colors when no installed picture is available.
nonisolated enum ItemAppearance {
    static let mapSymbol = "map.fill"

    static func symbol(for id: String) -> String {
        let name = ReadableName.identifierPath(id)
        func any(_ parts: [String]) -> Bool { parts.contains { name.hasSuffix($0) || name == $0 } }
        if any(["_helmet", "_chestplate", "_leggings", "_boots", "elytra", "_horse_armor", "wolf_armor"]) { return "tshirt.fill" }
        if any(["shield"]) { return "shield.fill" }
        if any(["_sword", "bow", "crossbow", "trident", "mace", "arrow"]) { return "scope" }
        if any(["_pickaxe", "_axe", "_shovel", "_hoe", "shears", "flint_and_steel", "brush"]) { return "hammer.fill" }
        if any(["fishing_rod", "cod", "salmon", "tropical_fish", "pufferfish"]) { return "fish.fill" }
        if any(["apple", "bread", "beef", "porkchop", "chicken", "mutton", "rabbit", "carrot", "potato", "cookie", "cake",
                "pie", "stew", "soup", "melon_slice", "berries", "beetroot", "dried_kelp", "honey_bottle", "chorus_fruit"]) {
            return "fork.knife"
        }
        if any(["potion", "_bottle", "dragon_breath"]) { return "flask.fill" }
        if any(["book", "book_and_quill"]) { return "book.closed.fill" }
        if any(["map", "compass", "clock", "spyglass"]) { return mapSymbol }
        if any(["diamond", "emerald", "_ingot", "_nugget", "lapis_lazuli", "quartz", "amethyst_shard", "netherite_scrap", "raw_iron",
                "raw_gold", "raw_copper", "coal", "charcoal", "redstone", "glowstone_dust"]) {
            return "diamond.fill"
        }
        if any(["shulker_box", "chest", "barrel", "bundle"]) { return "shippingbox.fill" }
        if any(["_seeds", "_sapling", "wheat", "_leaves", "flower", "tulip", "poppy", "dandelion", "kelp", "vine", "sugar_cane"]) {
            return "tree.fill"
        }
        if any(["bucket"]) { return "drop.fill" }
        if any(["torch", "lantern", "campfire", "blaze_rod", "fire_charge"]) { return "flame.fill" }
        if any(["totem_of_undying", "_spawn_egg", "ender_pearl", "ender_eye", "nether_star", "experience_bottle"]) { return "sparkles" }
        return "cube.fill"
    }

    static func tint(for id: String) -> Color {
        let name = id.lowercased()
        // First match wins, so "redstone" comes before "stone".
        let materials: [(String, Color)] = [
            ("netherite", .brown), ("diamond", .cyan), ("emerald", .green), ("gold", .yellow), ("iron", .gray),
            ("copper", .orange), ("leather", .brown), ("wooden", .brown), ("redstone", .red), ("stone", .gray),
            ("chainmail", .gray), ("lapis", .blue), ("amethyst", .purple), ("shulker", .purple),
        ]
        return materials.first { name.contains($0.0) }?.1 ?? .secondary
    }

    static func counted(_ label: String, count: Int, includingOne: Bool = false, locale: Locale = .current) -> String {
        guard includingOne || count != 1 else { return label }
        return String(localized: "\(count, format: .number.locale(locale)) \(label)", locale: locale)
    }

    static func durability(_ wear: ItemDurability, includingLabel: Bool = true, locale: Locale = .current) -> String {
        let format = IntegerFormatStyle<Int>.number.locale(locale)
        if !includingLabel {
            return String(localized: "\(wear.remaining, format: format) of \(wear.maximum, format: format)", locale: locale)
        }
        return String(localized: "Durability: \(wear.remaining, format: format) of \(wear.maximum, format: format)", locale: locale)
    }

    static func isEnchanted(_ item: ItemStack) -> Bool { !item.enchantments.isEmpty }

}

/// A player's health, hunger, experience, equipment and inventories, shown in the inspector.
struct PlayerDetailView: View {
    let session: WorldSession
    let player: PlayerInfo
    @Environment(\.gameNames) private var gameNames
    @Environment(\.locale) private var locale
    private var records: PlayerRecords? {
        session.selection.playerRecords?.uuid == player.uuid ? session.selection.playerRecords?.records : nil
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Game Mode", value: gameMode)
                if PlayerPresentation.position(of: player) == nil {
                    LabeledContent("Location", value: String(localized: "Location unknown"))
                }
                if let saved = player.lastSaved {
                    LabeledContent("Last Saved") { Text(saved, format: .dateTime.year().month().day().hour().minute()) }
                }
            } header: {
                InspectorHeading(title: Text(session.presentation.name(of: player)),
                                 symbol: MarkerStyle.playerAppearance(.player).symbol)
            }
            SelectedSearchSection(session: session)
            let locations = PlayerPresentation.locations(of: player)
            if !locations.isEmpty {
                Section("Locations") {
                    ForEach(locations) { location in
                        locationButton(location)
                    }
                }
            }
            Section("Status") {
                HealthRow(health: player.health,
                          maximum: player.maximumHealth(enchantments: session.details.definitions.enchantments))
                if let absorption = player.absorption, absorption > 0, let text = HealthPresentation.hearts(absorption, locale: locale) {
                    SavedStatusRow("Absorption") { Text(text) }
                }
                if let food = player.foodLevel {
                    let reading = HungerPresentation(food: food)
                    SavedStatusRow("Hunger") {
                        SavedStatusGauge(value: reading.gaugeValue, maximum: reading.maximum) {
                            Text(reading.value, format: CountedText.hunger(of: reading.maximum))
                        }
                        .tint(.orange)
                    }
                }
                if let level = player.experienceLevel {
                    SavedStatusRow("Experience") {
                        SavedStatusGauge(value: player.experienceProgress ?? 0, maximum: 1) {
                            Text("Level \(level)")
                        }
                        .tint(.green)
                    }
                }
            }
            PlayerEffectsSection(effects: player.activeEffects)
            EquipmentSection(items: player.equippedItems)
            LinkedPetsSection(session: session, playerID: player.uuid)
            ShoulderPetsSection(session: session, playerID: player.uuid)
            Section("Hotbar") {
                SlotGrid(slots: player.inventorySlots(in: .hotbar), selected: player.selectedSlot)
            }
            Section("Inventory") {
                SlotGrid(slots: player.inventorySlots(in: .storage))
            }
            Section("Ender Chest") {
                SlotGrid(slots: player.inventorySlots(in: .enderChest))
            }
            PlayerRecordsSections(records: records) { session.showStatistics(for: player.uuid) }
        }
        .formStyle(.grouped)
    }

    private var gameMode: String { gameNames.gameMode(player.gameMode) }

    private func locationButton(_ saved: PlayerPresentation.Location) -> some View {
        let location = saved.position
        return LocationRow(title: Text(gameNames.playerLocation(saved.kind, locale: locale)), session: session,
                           destination: MapDestination(coordinates: Coordinates(CGPoint(x: location.x, y: location.z), y: location.y),
                                                       dimension: location.dimension, isBlockPosition: saved.isBlockPosition),
                           showsDimension: true)
    }

}

/// Nine slots per row, like the game's inventory screen.
private struct SlotGrid: View {
    let slots: [ItemStack?]
    var selected: Int?

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<(slots.count / 9), id: \.self) { row in
                GridRow {
                    ForEach(0..<9, id: \.self) { column in
                        let index = row * 9 + column
                        SlotView(item: slots[index], isSelected: index == selected)
                    }
                }
            }
        }
    }
}

private struct SlotView: View {
    let item: ItemStack?
    let isSelected: Bool
    @Environment(\.gameNames) private var gameNames
    @Environment(\.locale) private var locale

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            .frame(width: 28, height: 28)
            .overlay {
                if let item {
                    ItemIcon(item: item)
                }
            }
            .overlay(alignment: .bottom) {
                if let reading = DurabilityPresentation(item?.durability), reading.isDamaged {
                    InventoryDurabilityBar(reading: reading)
                        .padding(.bottom, 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let item, item.count > 1 {
                    Text(item.count, format: .number)
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.trailing, 2)
                }
            }
            .help(item.map { gameNames.itemDetails(of: $0, locale: locale) } ?? "")
            .accessibilityElement()
            .accessibilityLabel(item.map { gameNames.itemDetails(of: $0, locale: locale) } ?? String(localized: "Empty"))
    }
}
