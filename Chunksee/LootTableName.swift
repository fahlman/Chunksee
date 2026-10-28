import Foundation

/// Labels describe the saved table, regardless of where its container was placed.
nonisolated enum LootTableName {
    static func name(_ table: String?) -> String {
        guard let table, !table.isEmpty else { return String(localized: "Unopened Loot") }
        if let path = ReadableName.vanillaPath(table), path.hasPrefix("chests/") {
            let name = path.dropFirst("chests/".count).split(separator: "/")
                .map { ReadableName.from(String($0)) }.joined(separator: " · ")
            if !name.isEmpty { return String(localized: "\(name) Loot") }
        }
        return String(localized: "Loot: \(table)")
    }
}
