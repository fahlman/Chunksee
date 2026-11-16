import ChunkseeKit
import Foundation
import Observation

/// Saved players depend on the world alone. Game discovery and definition failures cannot delay
/// their publication, and changing definitions does not reread their files.
@Observable
final class WorldPlayerLoader: PlayerSnapshotSource {
    typealias ReadPlayers = @Sendable (World) async -> [PlayerInfo]?

    private final class Reads {
        var players: ReadPlayers = { await WorldResources.readPlayers($0) }
    }

    private let reads: Reads
    private let loader: RefreshLoader<WorldReadSource, RefreshInvalidation, PlayerSnapshot>
    private let empty = PlayerSnapshot([])

    var snapshot: PlayerSnapshot { loader.value ?? empty }
    var work: BackgroundWork.Scope { loader.work }
    var readPlayers: ReadPlayers {
        get { reads.players }
        set { reads.players = newValue }
    }

    init(world: WorldReadSource, work: BackgroundWork, players: [PlayerInfo]) {
        let reads = Reads()
        self.reads = reads
        loader = RefreshLoader(work: work, priority: .utility, whenInactive: .finish,
            source: world, initialValue: PlayerSnapshot(players)) { source, _ in
                let read = await reads.players
                try Task.checkCancellation()
                guard let players = await read(source.world) else { throw CancellationError() }
                try Task.checkCancellation()
                return PlayerSnapshot(players)
            }
    }

    func refresh() {
        loader.request(source: loader.source, isEnabled: true, reread: true)
    }

    func replaceWorld(_ world: WorldReadSource, players: [PlayerInfo]) {
        loader.replace(source: world, value: PlayerSnapshot(players))
    }

    func close() { loader.close() }
}
