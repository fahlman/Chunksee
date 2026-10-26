import ChunkseeIndex
import ChunkseeKit
import Foundation

/// Saved profession names and inspector ranks; game interpretation belongs to ChunkseeKit.
nonisolated enum VillagerText {
    static func professionName(_ villager: Villager) -> String? {
        guard villager.isUnemployed == false, let profession = villager.profession else { return nil }
        return ReadableName.from(profession)
    }

    static func inspectorProfession(_ creature: Creature, definitions: TradingDefinitions? = nil) -> String? {
        guard let villager = creature.villager else { return nil }
        let name: String
        if let profession = professionName(villager) {
            name = profession
        } else if creature.id == "minecraft:villager", villager.isUnemployed == true {
            name = String(localized: "None")
        } else {
            return nil
        }
        // An unverified custom profession keeps its existing rank; only known false omits it.
        if villager.supportsTrading(using: definitions) == false { return name }
        guard let level = levelName(villager.level) else { return name }
        return String(localized: "\(name), \(level)")
    }

    static func levelName(_ level: Int?) -> String? {
        switch level {
        case 1: String(localized: "Novice")
        case 2: String(localized: "Apprentice")
        case 3: String(localized: "Journeyman")
        case 4: String(localized: "Expert")
        case 5: String(localized: "Master")
        default: nil
        }
    }
}
