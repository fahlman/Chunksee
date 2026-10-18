import ChunkseeKit

/// WorldResources publishes one immutable roster per completed read. Document searches share
/// its identity, so checking their sources never traverses the players' saved NBT.
nonisolated final class PlayerSnapshot: Sendable {
    let players: [PlayerInfo]

    init(_ players: [PlayerInfo]) { self.players = players }
}
