import ChunkseeKit
import SwiftUI

struct PlayerEquipmentSection: View {
    let player: PlayerInfo

    var body: some View {
        let items = equipped
        if !items.isEmpty {
            Section("Equipment") {
                ForEach(Self.slotOrder.filter { items[$0] != nil }, id: \.self) { slot in
                    if let item = items[slot] {
                        LabeledContent(PetDetailText.slot(slot)) {
                            VStack(alignment: .trailing) {
                                Label(ItemAppearance.name(of: item), systemImage: ItemAppearance.symbol(for: item.id))
                                    .foregroundStyle(ItemAppearance.tint(for: item.id))
                                if let wear = item.durability {
                                    Text("Durability: \(wear.remaining) of \(wear.maximum)")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                ForEach(item.enchantments.keys.sorted(), id: \.self) { id in
                                    Text(TradeText.enchantmentName(id, level: item.enchantments[id] ?? 1))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var equipped: [String: ItemStack] {
        var items = player.equipment
        items["mainhand"] = player.mainHandItem
        return items.filter { Self.slotOrder.contains($0.key) && $0.value.count > 0 }
    }

    private static let slotOrder = ["head", "chest", "legs", "feet", "mainhand", "offhand", "body", "saddle"]
}
