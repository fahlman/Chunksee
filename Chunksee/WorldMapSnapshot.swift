import ChunkseeKit
import Foundation

/// Saved pictures and their prepared content identities publish together. Kit owns discovery
/// and priority; this producer owns which prior values remain coherent after an incomplete read.
nonisolated struct WorldMapSnapshot: Sendable {
    let sources: [InGameMapImage.Source]

    static func read(_ world: World, retaining previous: Self? = nil) -> RefreshRead<Self> {
        let read = world.readMapItems()
        let old = Dictionary(uniqueKeysWithValues: (previous?.sources ?? []).map { ($0.map.id, $0) })
        let readable = Set(read.maps.map(\.id))
        var sources = read.maps.map { map in
            if let prior = old[map.id], read.unresolvedIDs.contains(map.id) || prior.map == map { return prior }
            return InGameMapImage.Source(map)
        }
        sources += old.values.filter {
            !readable.contains($0.map.id) && (!read.isListingComplete || read.unresolvedIDs.contains($0.map.id))
        }
        let snapshot = Self(sources: sources.sorted { $0.map.id < $1.map.id })
        return read.isListingComplete && read.unresolvedIDs.isEmpty ? .complete(snapshot) : .partial(snapshot)
    }
}

/// The Kit map reader uses only the world's root; each map file supplies its own saved metadata.
/// Changes to level facts, dimension catalogs, game definitions or artwork do not replace this source.
nonisolated struct WorldMapSource: Equatable, Sendable {
    let worldSource: WorldReadSource
}
