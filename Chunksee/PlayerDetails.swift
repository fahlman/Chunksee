import ChunkseeKit
import SwiftUI

/// How an item looks in a slot. Minecraft's textures can't be redistributed, so items are drawn as
/// an SF Symbol for their category, tinted by their material.
nonisolated enum ItemAppearance {
    static func symbol(for id: String) -> String {
        let name = id.split(separator: ":").last.map(String.init) ?? id
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
        if any(["map", "compass", "clock", "spyglass"]) { return "map.fill" }
        if any(["diamond", "emerald", "_ingot", "_nugget", "lapis_lazuli", "quartz", "amethyst_shard", "netherite_scrap", "raw_iron",
                "raw_gold", "raw_copper", "coal", "charcoal", "redstone", "glowstone_dust"]) {
            return "diamond.fill"
        }
        if any(["shulker_box", "chest", "barrel", "bundle"]) { return "shippingbox.fill" }
        if any(["_seeds", "_sapling", "wheat", "_leaves", "flower", "tulip", "poppy", "dandelion", "kelp", "vine", "sugar_cane"]) {
            return "leaf.fill"
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

    /// "64 Diamond", "Diamond Sword “Excalibur”, enchanted".
    static func description(of item: ItemStack) -> String {
        var text = name(of: item)
        if isEnchanted(item) { text = String(localized: "\(text), enchanted") }
        return text
    }

    static func name(of item: ItemStack) -> String {
        var text = ReadableName.from(item.id)
        if let name = item.customName { text += " “\(name)”" }
        return item.count > 1 ? "\(item.count) \(text)" : text
    }

    static func details(of item: ItemStack) -> String {
        var lines = [description(of: item)]
        lines += item.enchantments.sorted { $0.key < $1.key }.map { TradeText.enchantmentName($0.key, level: $0.value) }
        if let wear = item.durability { lines.append(durability(wear)) }
        return lines.joined(separator: "\n")
    }

    static func durability(_ wear: ItemDurability, locale: Locale = .current) -> String {
        let format = IntegerFormatStyle<Int>.number.locale(locale)
        return String(localized: "Durability: \(wear.remaining, format: format) of \(wear.maximum, format: format)", locale: locale)
    }

    static func isEnchanted(_ item: ItemStack) -> Bool { !item.enchantments.isEmpty }

    /// Items placed by slot into `count` slots starting at `first`; empty slots are `nil`.
    static func slots(_ items: [ItemStack], first: Int = 0, count: Int) -> [ItemStack?] {
        var slots = [ItemStack?](repeating: nil, count: count)
        for item in items {
            guard let slot = item.slot, slot >= first, slot < first + count else { continue }
            slots[slot - first] = item
        }
        return slots
    }
}

/// A player's health, hunger, experience, equipment and inventories, shown in the inspector.
struct PlayerDetailView: View {
    let session: WorldSession
    let player: PlayerInfo
    private var records: PlayerRecords? {
        session.playerRecords.uuid == player.uuid ? session.playerRecords.records : nil
    }
    @State private var showsAllStatistics = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Game Mode", value: gameMode)
                if let saved = player.lastSaved {
                    LabeledContent("Last Saved") { Text(saved, format: .dateTime.year().month().day().hour().minute()) }
                }
            } header: {
                Text(session.name(of: player)).font(.headline)
            }
            if PlayerPresentation.isMappable(player) {
                Section("Locations") {
                    if let location = player.position { locationButton("Last Position", location) }
                    if let location = player.lastDeath { locationButton("Last Death", location) }
                    if let location = player.respawn { locationButton("Respawn Point", location) }
                }
            }
            Section("Status") {
                HealthRow(health: player.health, maximum: player.maxHealth)
                if let absorption = player.absorption, absorption > 0, let text = HealthPresentation.hearts(absorption) {
                    LabeledContent("Absorption", value: text)
                }
                if let food = player.foodLevel {
                    LabeledContent("Hunger") {
                        Gauge(value: Double(min(food, 20)), in: 0...20) { EmptyView() } currentValueLabel: {
                            Text("\(Double(food) / 2, format: .number.precision(.fractionLength(0...1))) of 10")
                        }
                        .tint(.orange)
                    }
                }
                if let level = player.experienceLevel {
                    LabeledContent("Experience") {
                        Gauge(value: player.experienceProgress ?? 0, in: 0...1) { EmptyView() } currentValueLabel: {
                            Text("Level \(level)")
                        }
                        .tint(.green)
                    }
                }
            }
            PlayerEffectsSection(effects: player.activeEffects)
            EquipmentSection(items: EquipmentPresentation.items(for: player))
            LinkedPetsSection(session: session, playerID: player.uuid)
            Section("Hotbar") {
                SlotGrid(slots: ItemAppearance.slots(player.inventory, count: 9), selected: player.selectedSlot)
            }
            Section("Inventory") {
                SlotGrid(slots: ItemAppearance.slots(player.inventory, first: 9, count: 27))
            }
            Section("Ender Chest") {
                SlotGrid(slots: ItemAppearance.slots(player.enderChest, count: 27))
            }
            PlayerRecordsSections(records: records, showsAllStatistics: $showsAllStatistics)
        }
        .formStyle(.grouped)
        .task(id: RecordRequest(uuid: player.uuid, name: session.names.name(for: player.uuid), saved: player.lastSaved)) {
            await session.playerRecords.load(player.uuid, name: session.names.name(for: player.uuid))
        }
        .sheet(isPresented: $showsAllStatistics) {
            StatisticsTable(rows: records?.rows ?? [])
        }
    }

    private struct RecordRequest: Hashable {
        var uuid: UUID
        var name: String?
        var saved: Date?
    }

    private var gameMode: String {
        switch player.gameMode {
        case .survival: String(localized: "Survival")
        case .creative: String(localized: "Creative")
        case .adventure: String(localized: "Adventure")
        case .spectator: String(localized: "Spectator")
        case nil: String(localized: "Unknown")
        }
    }

    private func locationButton(_ title: LocalizedStringKey, _ location: PlayerInfo.Location) -> some View {
        Button { session.focus(on: location) } label: {
            LabeledContent(title, value: String(localized: "\(session.dimensionName(location.dimension)): X \(Int(location.x)), Y \(Int(location.y)), Z \(Int(location.z))"))
        }
        .disabled(!session.dimensions.contains { $0.id == location.dimension })
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

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            .frame(width: 28, height: 28)
            .overlay {
                if let item {
                    Image(systemName: ItemAppearance.symbol(for: item.id))
                        .foregroundStyle(ItemAppearance.tint(for: item.id))
                        .shadow(color: ItemAppearance.isEnchanted(item) ? .purple : .clear, radius: 3)
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
            .help(item.map(ItemAppearance.details(of:)) ?? "")
            .accessibilityElement()
            .accessibilityLabel(item.map(ItemAppearance.details(of:)) ?? String(localized: "Empty"))
    }
}
