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

/// Captured when this window starts a query. Selection and panning never edit it. A saved
/// player identity follows only that player's published position, retaining the last point
/// if the player disappears or leaves the dimension.
nonisolated struct BlockSearchAnchor: Equatable, Sendable {
    var point: BlockSearchPoint
    let playerID: UUID?

    mutating func update(players: [PlayerInfo]) {
        guard let playerID, let location = players.first(where: { $0.uuid == playerID })?.location,
              location.dimension == point.dimension,
              let origin = BlockSearchOrigin(x: location.x, z: location.z) else { return }
        point = BlockSearchPoint(dimension: point.dimension, origin: origin)
    }
}

nonisolated struct BlockQueryInput: Sendable, Equatable {
    let counts: BlockCountSnapshot
    let catalog: NotableBlock.Catalog
    let point: BlockSearchPoint

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.counts === rhs.counts && lhs.catalog == rhs.catalog && lhs.point == rhs.point
    }
}
