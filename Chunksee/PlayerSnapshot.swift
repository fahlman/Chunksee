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

/// Consumers read one producer's immutable snapshot. Definitions and their dependent players
/// can share a publication without copying the players into another mutable roster.
protocol PlayerSnapshotSource: AnyObject {
    var snapshot: PlayerSnapshot { get }
}

/// An independently supplied roster, also used by standalone search/index clients.
@Observable
final class PlayerRoster: PlayerSnapshotSource {
    private(set) var snapshot: PlayerSnapshot

    init(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }

    func publish(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }
}
