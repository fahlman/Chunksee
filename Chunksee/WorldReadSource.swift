import ChunkseeKit

/// One admitted opening, reread or move. The folder's persistent identity belongs to the app
/// registry; this identity retires work even when a reread keeps exactly the same URL.
nonisolated final class WorldReadSource: Equatable, Sendable {
    let world: World

    init(_ world: World) { self.world = world }

    static func == (lhs: WorldReadSource, rhs: WorldReadSource) -> Bool { lhs === rhs }
}
