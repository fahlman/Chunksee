import ChunkseeKit
import SwiftUI

/// Native equipment rows shared by player and creature inspectors.
struct EquipmentSection: View {
    let items: [String: ItemStack]

    var body: some View {
        let rows = EquipmentPresentation.rows(items)
        if !rows.isEmpty {
            Section("Equipment") {
                ForEach(rows) { row in
                    VStack(alignment: .leading) {
                        LabeledContent(EquipmentPresentation.slot(row.slot)) {
                            VStack(alignment: .trailing) {
                                ItemLabel(id: row.item.id, title: Text(row.item, format: ItemAppearance.LabelStyle()),
                                          isEnchanted: ItemAppearance.isEnchanted(row.item))
                                .foregroundStyle(.primary)
                                .help(ItemAppearance.details(of: row.item))
                                ForEach(row.item.enchantments.keys.sorted(), id: \.self) { id in
                                    Text(id, format: TradeText.EnchantmentStyle(level: row.item.enchantments[id] ?? 1))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        // A labeled row inside another row's value inherits its trailing layout.
                        if let reading = DurabilityPresentation(row.item.durability) {
                            DurabilityRow(reading: reading)
                        }
                    }
                }
            }
        }
    }
}

nonisolated enum EquipmentPresentation {
    struct Row: Identifiable {
        var slot: String
        var item: ItemStack
        var id: String { slot }
    }

    static func items(for player: PlayerInfo) -> [String: ItemStack] {
        player.equippedItems.filter { slotOrder.contains($0.key) && $0.key != "storage" }
    }

    static func rows(_ items: [String: ItemStack]) -> [Row] {
        let filled = items.filter { $0.value.count > 0 }
        let slots = slotOrder + filled.keys.filter { !slotOrder.contains($0) }.sorted()
        return slots.compactMap { slot in filled[slot].map { Row(slot: slot, item: $0) } }
    }

    private static let slotOrder = ["head", "chest", "legs", "feet", "mainhand", "offhand", "body", "saddle", "storage"]

    static func slot(_ slot: String) -> String {
        switch slot {
        case "body": String(localized: "Body")
        case "saddle": String(localized: "Saddle")
        case "storage": String(localized: "Storage")
        case "head": String(localized: "Head")
        case "chest": String(localized: "Chest")
        case "legs": String(localized: "Legs")
        case "feet": String(localized: "Feet")
        case "mainhand": String(localized: "Main Hand")
        case "offhand": String(localized: "Off Hand")
        default: ReadableName.from(slot)
        }
    }
}
