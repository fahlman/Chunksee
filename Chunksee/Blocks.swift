import ChunkseeKit
import ChunkseeIndex
import Foundation

/// Shared block groups and quantities; the app supplies their localized presentation.
typealias NotableBlock = ChunkseeIndex.NotableBlock
typealias BlockDeposit = NotableBlock.Deposit

extension NotableBlock {
    nonisolated var name: String {
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
    nonisolated var searchText: String { ([name] + ids).joined(separator: " ") }
}

/// A chunk's deposit as retained and sorted by the shared dimension index.
typealias ChunkDeposit = ChunkseeIndex.DimensionIndex.ChunkDeposit
