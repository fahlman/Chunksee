import ChunkseeIndex
import ChunkseeKit
import Foundation

/// A broad notification supersedes individual regions, including ones queued during a read.
nonisolated enum RegionChange: Sendable, Equatable {
    case all
    case regions(Set<RegionPosition>)

    mutating func merge(_ next: Self) {
        if case .regions(let current) = self, case .regions(let added) = next {
            self = .regions(current.union(added))
        } else { self = .all }
    }

    /// Nil tells the map to reconcile the complete dimension.
    var mapRegions: Set<RegionPosition>? {
        if case .regions(let regions) = self { return regions }
        return nil
    }
}

/// Cached native projections for a shared region contribution. Replaced only when that region
/// was read successfully; unchanged regions do not rebuild structure geometry or creature wrappers.
nonisolated struct RegionIndex: Sendable {
    let index: ChunkseeIndex.RegionIndex
    let structures: [StructureMarker]
    let creatures: [CreatureMarker]

    @concurrent
    static func read(_ reader: RegionReader, region: RegionPosition) async -> RegionIndex? {
        guard let facts = await reader.facts(region) else { return nil }
        let index = ChunkseeIndex.RegionIndex(facts, caveBiomeIDs: BiomePresentation.caveBiomeIDs)
        return RegionIndex(index: index, structures: index.structures.map { StructureMarker($0, groups: reader.structureGroups) },
                           creatures: index.creatures.map { CreatureMarker($0, dimension: index.dimension) })
    }
}
