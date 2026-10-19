import ChunkseeKit
import Observation

/// WorldResources publishes one immutable player snapshot per completed read. Document searches share
/// its identity, so checking their sources never traverses the players' saved NBT.
nonisolated final class PlayerSnapshot: Sendable {
    let players: [PlayerInfo]
    let shoulderPets: [ShoulderPet]

    init(_ players: [PlayerInfo]) {
        self.players = players
        shoulderPets = players.flatMap { player in
            player.shoulderPets.enumerated().map { ShoulderPet(creature: $0.element, carrier: player, index: $0.offset) }
        }
    }
}

/// One observable publication for all searches and inspectors in a world. Background queries
/// capture its immutable snapshot; refreshing publishes once instead of pushing into each tab.
@Observable
final class PlayerRoster {
    private(set) var snapshot: PlayerSnapshot

    init(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }

    func publish(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }
}
