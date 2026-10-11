import ChunkseeKit
import Foundation

/// Blocks worth finding that the region pass counts: valuable ores, spawners and budding
/// amethyst. Common ores (coal, iron, copper, redstone) are left out: they're in a third of all
/// sections, which made counting them several times costlier, and they're easy to find anyway
/// (measured on Ryan's Realm, fahlman/Chunksee#81).
nonisolated enum NotableBlock: String, CaseIterable, Codable, Sendable {
    case diamond, emerald, gold, netherGold, lapis, ancientDebris, spawner, trialSpawner, buddingAmethyst

    /// The block ids counted together, deepslate variants included.
    var ids: [String] {
        switch self {
        case .diamond: ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"]
        case .emerald: ["minecraft:emerald_ore", "minecraft:deepslate_emerald_ore"]
        case .gold: ["minecraft:gold_ore", "minecraft:deepslate_gold_ore"]
        case .netherGold: ["minecraft:nether_gold_ore"]
        case .lapis: ["minecraft:lapis_ore", "minecraft:deepslate_lapis_ore"]
        case .ancientDebris: ["minecraft:ancient_debris"]
        case .spawner: ["minecraft:spawner"]
        case .trialSpawner: ["minecraft:trial_spawner"]
        case .buddingAmethyst: ["minecraft:budding_amethyst"]
        }
    }

    var name: String {
        switch self {
        case .diamond: String(localized: "Diamond Ore")
        case .emerald: String(localized: "Emerald Ore")
        case .gold: String(localized: "Gold Ore")
        case .netherGold: String(localized: "Nether Gold Ore")
        case .lapis: String(localized: "Lapis Lazuli Ore")
        case .ancientDebris: String(localized: "Ancient Debris")
        case .spawner: String(localized: "Spawner")
        case .trialSpawner: String(localized: "Trial Spawner")
        case .buddingAmethyst: String(localized: "Budding Amethyst")
        }
    }

    /// The text `block:` searches match: the name and every id.
    var searchText: String { ([name] + ids).joined(separator: " ") }

    static let byID: [String: NotableBlock] = Dictionary(uniqueKeysWithValues: allCases.flatMap { block in block.ids.map { ($0, block) } })
}

/// How much of one notable block a chunk holds, and the height range of the sections it's in.
nonisolated struct BlockDeposit: Codable, Equatable, Sendable {
    var block: NotableBlock
    var count: Int
    var minY: Int
    var maxY: Int

    /// The notable blocks in a chunk, counted from each section's palette without reading every
    /// block; sections whose palette has none are skipped entirely.
    static func deposits(in chunk: Chunk) -> [BlockDeposit] {
        var found: [NotableBlock: BlockDeposit] = [:]
        for section in chunk.sections {
            guard let states = section.blockStates else { continue }
            let wanted = states.palette.indices.compactMap { i in NotableBlock.byID[states.palette[i].id].map { (i, $0) } }
            guard !wanted.isEmpty else { continue }
            let counts = states.paletteCounts()
            for (index, block) in wanted where counts[index] > 0 {
                let bottom = section.y * 16, top = bottom + 15
                if var deposit = found[block] {
                    deposit.count += counts[index]
                    deposit.minY = min(deposit.minY, bottom)
                    deposit.maxY = max(deposit.maxY, top)
                    found[block] = deposit
                } else {
                    found[block] = BlockDeposit(block: block, count: counts[index], minY: bottom, maxY: top)
                }
            }
        }
        return found.values.sorted { $0.block.rawValue < $1.block.rawValue }
    }
}

/// A chunk's deposit of one notable block, as the world index lists them.
nonisolated struct ChunkDeposit: Equatable, Sendable {
    var chunk: ChunkCoordinate
    var deposit: BlockDeposit
}
