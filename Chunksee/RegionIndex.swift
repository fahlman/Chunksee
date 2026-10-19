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

/// Retained index inputs for one coordinate, including terrain, entities and raw POI blocks.
/// Only displayed creatures are retained; chunk NBT and inhabited-time arrays are not.
nonisolated struct RegionIndex: Sendable {
    var contents: SearchContents
    var structures: [StructureMarker]
    var creatures: [CreatureMarker]
    var biomes: [ChunkPosition: String]
    var caveBiomes: [ChunkPosition: [String]]
    var blocks: [ChunkPosition: [BlockDeposit]]
    var formats: ChunkFormats
    var pointsOfInterest: [PointOfInterest]

    @concurrent
    static func read(_ reader: RegionReader, region: RegionPosition) async -> RegionIndex? {
        guard let facts = await reader.facts(region) else { return nil }
        let blocks = Dictionary(uniqueKeysWithValues: facts.chunks.compactMap { chunk in
            let deposits = BlockDeposit.grouped(chunk.blockDeposits)
            return deposits.isEmpty ? nil : (chunk.position, deposits)
        })
        return RegionIndex(contents: facts.searchContents, structures: facts.structures.map(StructureMarker.init),
                           creatures: facts.creatures.compactMap { CreatureMarker($0, dimension: facts.dimension) },
                           biomes: facts.surfaceBiomes, caveBiomes: facts.caveBiomes, blocks: blocks,
                           formats: ChunkFormats(readable: facts.formats.readable, legacy: facts.formats.legacy),
                           pointsOfInterest: facts.pointsOfInterest)
    }
}
