import ChunkseeKit
import ChunkseeIndex
import Foundation

/// Shared block groups and quantities; the app supplies their localized presentation.
typealias NotableBlock = ChunkseeIndex.NotableBlock
typealias BlockDeposit = NotableBlock.Deposit

extension NotableBlock {
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.notableBlock(self) }

    /// The text `block:` searches match: the name and every id.
    nonisolated func searchText(in catalog: NotableBlock.Catalog?, gameNames: GameNames) -> String {
        gameNames.notableBlockSearchText(self, in: catalog)
    }
}

/// A chunk's deposit as retained and sorted by the shared dimension index.
typealias ChunkDeposit = ChunkseeIndex.DimensionIndex.ChunkDeposit
