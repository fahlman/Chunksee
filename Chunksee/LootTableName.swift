import Foundation

/// Labels describe the saved table, regardless of where its container was placed.
nonisolated enum LootTableName {
    static func name(_ table: String?) -> String {
        guard let table, !table.isEmpty else { return String(localized: "Unopened Loot") }
        switch ReadableName.vanillaPath(table) {
        case "chests/simple_dungeon": return String(localized: "Monster Room Loot")
        case "chests/abandoned_mineshaft": return String(localized: "Mineshaft Loot")
        case "chests/desert_pyramid": return String(localized: "Desert Pyramid Loot")
        case "chests/jungle_temple": return String(localized: "Jungle Pyramid Loot")
        case "chests/buried_treasure": return String(localized: "Buried Treasure Loot")
        case "chests/shipwreck_treasure": return String(localized: "Shipwreck Treasure Loot")
        case "chests/shipwreck_supply": return String(localized: "Shipwreck Supply Loot")
        case "chests/shipwreck_map": return String(localized: "Shipwreck Map Loot")
        default:
            if let path = ReadableName.vanillaPath(table), path.hasPrefix("chests/") {
                let name = path.dropFirst("chests/".count).split(separator: "/")
                    .map { ReadableName.from(String($0)) }.joined(separator: " · ")
                if !name.isEmpty { return String(localized: "\(name) Loot") }
            }
            return String(localized: "Loot: \(table)")
        }
    }
}
