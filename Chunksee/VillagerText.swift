import ChunkseeKit
import Foundation

/// Saved villager job/level labels, shared by the inspector, marker and trade search.
nonisolated enum VillagerText {
    static func jobName(_ villager: Villager) -> String? {
        guard let job = villager.profession, !job.isEmpty, job != "minecraft:none" else { return nil }
        return ReadableName.from(job)
    }

    static func description(_ villager: Villager) -> String? {
        guard let job = jobName(villager) else { return nil }
        guard let level = levelName(villager.level) else { return job }
        return String(localized: "\(job), \(level)")
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
