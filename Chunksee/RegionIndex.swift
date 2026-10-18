import ChunkseeKit
import Foundation

/// A broad notification supersedes individual regions, including ones queued during a read.
nonisolated enum RegionChange: Sendable, Equatable {
    case all
    case regions(Set<RegionCoordinate>)

    mutating func merge(_ next: Self) {
        if case .regions(let current) = self, case .regions(let added) = next {
            self = .regions(current.union(added))
        } else { self = .all }
    }

    /// Nil tells the map to reconcile the complete dimension.
    var mapRegions: Set<RegionCoordinate>? {
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
    var biomes: [ChunkCoordinate: String]
    var caveBiomes: [ChunkCoordinate: [String]]
    var blocks: [ChunkCoordinate: [BlockDeposit]]
    var formats: ChunkFormats
    var pointsOfInterest: [PointOfInterest]

    @concurrent
    static func read(_ reader: RegionReader, region: RegionCoordinate) async -> RegionIndex {
        async let data = reader.indexData(region)
        async let points = PlaceScanner.blocks(reader.dimension, region: region, cache: reader.cache)
        let found = await data
        let pois = await points
        return RegionIndex(contents: found.contents, structures: found.structures,
                                 creatures: found.creatures.compactMap { CreatureMarker($0, dimension: reader.dimension.id) },
                                 biomes: found.biomes, caveBiomes: found.caveBiomes, blocks: found.blocks,
                                 formats: found.formats, pointsOfInterest: pois)
    }
}
