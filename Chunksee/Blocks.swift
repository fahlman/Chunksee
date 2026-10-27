import ChunkseeKit
import ChunkseeIndex
import Foundation

/// Shared block groups and quantities; the app supplies their localized presentation.
typealias NotableBlock = ChunkseeIndex.NotableBlock
typealias BlockDeposit = NotableBlock.Deposit

extension NotableBlock {
    // These are the existing presentation groups' representative blocks, not a membership
    // catalog. Membership still comes from the world's tags in ChunkseeIndex.
    private nonisolated var nameID: String {
        switch self {
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

    nonisolated func name(in gameNames: GameNames) -> String { gameNames.name(nameID, in: "block") }
    nonisolated var name: String { name(in: GameNames()) }

    /// The text `block:` searches match: the name and every id.
    nonisolated func searchText(in catalog: NotableBlock.Catalog?, gameNames: GameNames = GameNames()) -> String {
        ([name(in: gameNames), nameID] + (catalog?.ids(for: self) ?? []).sorted()).joined(separator: " ")
    }
}

/// A chunk's deposit as retained and sorted by the shared dimension index.
typealias ChunkDeposit = ChunkseeIndex.DimensionIndex.ChunkDeposit
