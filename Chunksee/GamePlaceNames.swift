import ChunkseeIndex
import ChunkseeKit
import Foundation

extension GameNames {
    nonisolated func biome(_ id: String) -> String { name(id, in: "biome") }

    /// Structures have no game-supplied display names; preserve the saved ID's word order.
    nonisolated func structure(_ id: String) -> String { ReadableName.from(id) }

    nonisolated func group(_ group: BiomeGroup) -> String { biome(group.id) }

    nonisolated func group(_ group: StructureGroup) -> String {
        switch group {
        case .village: String(localized: "Villages")
        case .stronghold: String(localized: "Strongholds")
        case .ancientCity: String(localized: "Ancient Cities")
        case .trialChambers: String(localized: "Trial Chambers")
        case .monument: String(localized: "Ocean Monuments")
        case .mansion: String(localized: "Woodland Mansions")
        case .temple: String(localized: "Temples and Huts")
        case .ruins: String(localized: "Ruins")
        case .ruinedPortal: String(localized: "Ruined Portals")
        case .shipwreck: String(localized: "Shipwrecks")
        case .buriedTreasure: String(localized: "Buried Treasure")
        case .outpost: String(localized: "Pillager Outposts")
        case .mineshaft: String(localized: "Mineshafts")
        case .fortress: String(localized: "Nether Fortresses")
        case .bastion: String(localized: "Bastion Remnants")
        case .netherFossil: String(localized: "Nether Fossils")
        case .endCity: String(localized: "End Cities")
        case .abandonedCamp: String(localized: "Abandoned Camps")
        case .other: String(localized: "Other Structures")
        }
    }

    nonisolated func group(_ group: PlaceGroup) -> String {
        switch group {
        case .portal: String(localized: "Nether Portals")
        case .bell: String(localized: "Village Bells")
        case .lodestone: String(localized: "Lodestones")
        case .bed: String(localized: "Beds")
        case .workstation: String(localized: "Villager Workstations")
        case .beeNest: String(localized: "Bee Nests and Hives")
        case .lightningRod: String(localized: "Lightning Rods")
        case .spawner: String(localized: "Monster Spawners")
        case .unopenedLoot: String(localized: "Unopened Loot")
        case .other: String(localized: "Other Places")
        }
    }

    nonisolated func group(_ group: CreatureGroup) -> String {
        switch group {
        case .named: String(localized: "Named Creatures")
        case .pet: String(localized: "Pets")
        case .villager: String(localized: "Villagers and Traders")
        case .mob: String(localized: "Mobs")
        }
    }

    nonisolated func biomeArea(_ area: BiomeArea) -> String { String(localized: "\(area.chunkCount) chunks") }

    nonisolated func biomeDescription(surface: String?, caves: [String], locale: Locale = .current) -> String? {
        let caves = caves.map(biome)
        let below = caves.isEmpty ? nil
            : String(localized: "\(caves.formatted(.list(type: .and).locale(locale))) below", locale: locale)
        let parts = [surface.map(biome), below].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated func place(_ marker: PlaceMarker) -> String {
        switch marker.group {
        case .portal: return netherPortal()
        case .bell:
            return translation("minecraft:bell", in: "block") ?? String(localized: "Village Bell")
        case .lodestone: return translation(marker.type, in: "block") ?? String(localized: "Lodestone")
        case .beeNest:
            return translation(marker.type, in: "block")
                ?? (ReadableName.vanillaPath(marker.type) == "beehive" ? String(localized: "Beehive") : String(localized: "Bee Nest"))
        case .lightningRod: return translation(marker.type, in: "block") ?? String(localized: "Lightning Rod")
        // The point of interest identifies a bed, but not the block's color. Keep that distinction.
        case .bed: return marker.isClaimed ? String(localized: "Villager’s Bed") : String(localized: "Bed")
        case .workstation:
            return String(localized: "\(profession(marker.type))’s Workstation")
        // Name the saved mob, regardless of the spawner's surroundings.
        case .spawner:
            return marker.mob.map { String(localized: "\(entity($0)) Spawner") } ?? String(localized: "Empty Spawner")
        case .unopenedLoot: return lootTable(marker.lootTable)
        case .other: return ReadableName.from(marker.type)
        }
    }

    nonisolated func netherPortal() -> String {
        translation("minecraft:nether_portal", in: "block") ?? String(localized: "Nether Portal")
    }

    /// A loot container may be a block or an entity; its saved location supplies that distinction.
    nonisolated func lootContainer(_ marker: PlaceMarker) -> String {
        name(marker.type, in: marker.blockPosition == nil ? "entity" : "block")
    }

    nonisolated func lootTable(_ table: String?) -> String {
        guard let table, !table.isEmpty else { return String(localized: "Unopened Loot") }
        if let path = ReadableName.vanillaPath(table), path.hasPrefix("chests/") {
            let name = path.dropFirst("chests/".count).split(separator: "/")
                .map { ReadableName.from(String($0)) }.joined(separator: " · ")
            if !name.isEmpty { return String(localized: "\(name) Loot") }
        }
        return String(localized: "Loot: \(table)")
    }

    nonisolated func notableBlock(_ block: NotableBlock) -> String { name(notableBlockID(block), in: "block") }

    nonisolated func notableBlockSearchText(_ block: NotableBlock, in catalog: NotableBlock.Catalog?) -> String {
        ([notableBlock(block), notableBlockID(block)] + (catalog?.ids(for: block) ?? []).sorted()).joined(separator: " ")
    }

    // Representative labels for the existing presentation groups; membership comes from Kit's tags.
    private nonisolated func notableBlockID(_ block: NotableBlock) -> String {
        switch block {
        case .diamond: "minecraft:diamond_ore"
        case .emerald: "minecraft:emerald_ore"
        case .gold: "minecraft:gold_ore"
        case .netherGold: "minecraft:nether_gold_ore"
        case .lapis: "minecraft:lapis_ore"
        case .ancientDebris: "minecraft:ancient_debris"
        case .spawner: "minecraft:spawner"
        case .trialSpawner: "minecraft:trial_spawner"
        case .buddingAmethyst: "minecraft:budding_amethyst"
        }
    }
}
