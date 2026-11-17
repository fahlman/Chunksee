import ChunkseeKit
import Observation
@testable import ChunkseeTestHost

/// A controlled player source for focused index/search tests. App worlds use WorldPlayerLoader.
@Observable
final class PlayerRoster: PlayerSnapshotSource {
    private(set) var snapshot: PlayerSnapshot

    init(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }

    func publish(_ players: [PlayerInfo]) { snapshot = PlayerSnapshot(players) }
}
