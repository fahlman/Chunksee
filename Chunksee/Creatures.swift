import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI

/// Kinds of creatures the map can show. Farm animals and monsters number in the tens of thousands,
/// so only creatures someone cared about are shown: named ones, pets and villagers.
nonisolated enum CreatureGroup: String, CaseIterable, Codable, Sendable {
    case named, pet, villager

    var name: String {
        switch self {
        case .named: String(localized: "Named Creatures")
        case .pet: String(localized: "Pets")
        case .villager: String(localized: "Villagers and Traders")
        }
    }

    var symbol: String {
        switch self {
        case .named: "tag.fill"
        case .pet: "pawprint.fill"
        case .villager: "person.crop.square.fill"
        }
    }

    /// Marker color as sRGB hex.
    var color: UInt32 {
        switch self {
        case .named: 0x2E7D32
        case .pet: 0xAD1457
        case .villager: 0x795548
        }
    }

    var isShownByDefault: Bool { self != .villager }

    /// Villagers first (their trades are the reason to look), then pets, then other named creatures.
    static func group(for creature: Creature) -> CreatureGroup? {
        if creature.villager != nil { return .villager }
        if creature.owner != nil { return .pet }
        if creature.customName != nil { return .named }
        return nil
    }
}

/// A creature on the map.
nonisolated struct CreatureMarker: Identifiable, Equatable, Sendable {
    var id: String
    var creature: Creature
    var group: CreatureGroup
    var dimension: String
    /// Present only for a player-carried pet; this is independent of its saved owner.
    var carrier: UUID?

    var position: CGPoint { CGPoint(x: creature.x, y: creature.z) }

    /// "Summer", or the kind for unnamed ones: "Wolf", "Farmer" for a villager with a job.
    var name: String {
        if let name = creature.customName { return name }
        if let villager = creature.villager, let job = VillagerText.jobName(villager) { return job }
        return ReadableName.from(creature.id)
    }

    init?(_ creature: Creature, dimension: String) {
        guard let group = CreatureGroup.group(for: creature),
              Coordinates.canLocate(x: creature.x, y: creature.y, z: creature.z) else { return nil }
        self.creature = creature
        self.group = group
        self.dimension = dimension
        id = creature.uuid.map { "creature:\($0.uuidString.lowercased())" }
            ?? "\(creature.id)@\(creature.x),\(creature.y),\(creature.z)"
    }
}

/// Reads every shown creature in a dimension, in parallel by region.
nonisolated enum CreatureScanner {
    @concurrent
    static func scan(_ reader: RegionReader) async -> [CreatureMarker] {
        let dimension = reader.dimension.id
        return await reader.everyRegion { await $0.creatures($1) }.flatMap(\.value)
            .compactMap { CreatureMarker($0, dimension: dimension) }.sorted { $0.id < $1.id }
    }
}

/// Details of the selected creature in the inspector: kind, owner, and a villager's job and trades.
struct CreatureDetailView: View {
    let session: WorldSession
    let marker: CreatureMarker

    var body: some View {
        Form {
            Section {
                LabeledContent("Kind", value: ReadableName.from(marker.creature.id))
                LabeledContent("Position") {
                    Text(Coordinates.text(marker.position, y: marker.creature.y))
                        .monospacedDigit()
                }
                HealthRow(health: marker.creature.health, maximum: marker.creature.maxHealth)
                if let owner = marker.creature.owner {
                    LabeledContent("Tamed By", value: session.presentation.name(ofPlayerWith: owner))
                    PetDetailRows(creature: marker.creature)
                }
                if let carrier = marker.carrier {
                    LabeledContent("Riding With", value: session.presentation.name(ofPlayerWith: carrier))
                }
                if let villager = marker.creature.villager {
                    if let job = VillagerText.description(villager) {
                        LabeledContent("Job", value: job)
                    } else if marker.creature.id == "minecraft:villager" {
                        LabeledContent("Job", value: String(localized: "None yet"))
                    }
                }
            } header: {
                Label(marker.name, systemImage: marker.group.symbol).font(.headline)
            }
            if marker.creature.owner != nil, let equipment = marker.creature.equipment {
                EquipmentSection(items: equipment)
            }
            if let trades = marker.creature.villager?.trades, !trades.isEmpty {
                Section("Trades") {
                    ForEach(Array(trades.enumerated()), id: \.offset) { _, trade in
                        HStack {
                            Text(TradeText.cost(of: trade))
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(TradeText.describe(trade.sell))
                        }
                        .strikethrough(trade.isSoldOut)
                        .foregroundStyle(trade.isSoldOut ? .secondary : .primary)
                        .help(trade.isSoldOut ? "Sold out until the villager restocks" : "")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// How villagers and their trades read, in the creature details and in trade search.
nonisolated enum TradeText {
    /// "24 Emerald", "1 Enchanted Book (Mending)", "1 Diamond Sword (Sharpness V)".
    static func describe(_ item: ItemStack) -> String {
        let base = ItemAppearance.name(of: item, includingOne: true)
        let enchantments = item.enchantments.sorted { $0.key < $1.key }.map { enchantmentName($0.key, level: $0.value) }
        return enchantments.isEmpty ? base : "\(base) (\(enchantments.joined(separator: ", ")))"
    }

    /// What the villager asks for: "24 Emerald + 1 Book".
    static func cost(of trade: Trade) -> String {
        describe(trade.buy) + (trade.buyB.map { " + " + describe($0) } ?? "")
    }

    /// The text trade search matches: every item's name and id, and the enchantments' names.
    static func searchText(of trade: Trade) -> String {
        let items = [trade.buy, trade.sell] + (trade.buyB.map { [$0] } ?? [])
        return items.flatMap { [ItemAppearance.label(of: $0), $0.id] + $0.enchantments.keys.map { ReadableName.from($0) } }
            .joined(separator: " ")
    }

    static func enchantmentName(_ id: String, level: Int) -> String {
        if level == 1, singleLevelEnchantments.contains(id) { return ReadableName.from(id) }
        return ReadableName.from(id) + " " + LevelText.numeral(level)
    }

    // Vanilla 26.3 data/minecraft/enchantment/*.json. The game hides the suffix only when
    // both the saved and maximum levels are 1; unknown/modded enchantments keep their level.
    private static let singleLevelEnchantments: Set<String> = [
        "minecraft:aqua_affinity", "minecraft:binding_curse", "minecraft:channeling",
        "minecraft:flame", "minecraft:infinity", "minecraft:mending", "minecraft:multishot",
        "minecraft:silk_touch", "minecraft:vanishing_curse",
    ]
}
