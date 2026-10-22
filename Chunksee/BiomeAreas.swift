import Foundation
import ChunkseeKit
import ChunkseeIndex
import SwiftUI

/// A biome, as a sidebar group.
nonisolated struct BiomeGroup: MapLayerGroup, Sendable {
    static let symbol = "leaf.fill"

    var id: String
    var name: String { ReadableName.from(id) }
    var symbol: String { Self.symbol }
}

/// A patch of neighboring chunks with the same biome: at the surface, or for a cave biome, anywhere
/// underground.
nonisolated struct BiomeArea: MapLayerMarker, Sendable {
    var id: String
    var group: BiomeGroup
    var chunkCount: Int
    /// The center of the area's chunk nearest its middle, so it lies inside the area.
    var position: CGPoint
    /// World X/Z rectangle around the area, for skipping areas out of view.
    var bounds: CGRect
    /// The area's chunks, and the chunk edges around it, in world X/Z.
    var chunks: Path
    var outline: Path
    var name: String { String(localized: "\(chunkCount) chunks") }
    var yCoordinate: Double? { nil }
    var searchText: String { group.name + " " + group.id }
}

/// Biome areas, and every sampled chunk's biomes for the hover readout.
nonisolated struct BiomeScan: Sendable {
    var areas: [BiomeArea] = []
    var biomes: [ChunkPosition: String] = [:]
    /// Cave biomes under each chunk that has any.
    var caveBiomes: [ChunkPosition: [String]] = [:]
}

/// Finds biome areas by sampling one surface column per chunk and joining neighboring chunks of
/// the same biome. Each chunk's sections also identify cave biomes the surface sample can miss,
/// and their areas are found the same way.
nonisolated enum BiomeScanner {
    /// Biomes that generate only underground.
    static let caveBiomeIDs: Set<String> = [
        "minecraft:deep_dark", "minecraft:lush_caves", "minecraft:dripstone_caves", "minecraft:sulfur_caves",
    ]

    @concurrent
    static func scan(_ reader: RegionReader) async -> BiomeScan {
        var scan = BiomeScan()
        for part in await reader.everyRegion({ await $0.facts($1) }) {
            guard let facts = part.value else { continue }
            scan.biomes.merge(facts.surfaceBiomes) { $1 }
            scan.caveBiomes.merge(facts.caveBiomes) { $1 }
        }
        scan.areas = areas(surface: scan.biomes, caves: scan.caveBiomes)
        return scan
    }

    /// Every biome's areas, each chunk counted once per biome. A cave biome sometimes reaches the
    /// surface sample, but its underground membership already covers that chunk, so its areas come
    /// only from there; the hover readout still names the surface biome.
    static func areas(surface: [ChunkPosition: String], caves: [ChunkPosition: [String]]) -> [BiomeArea] {
        areas(from: surface.filter { !caveBiomeIDs.contains($0.value) }) + caveAreas(from: caves)
    }

    /// Areas of each cave biome; a chunk can belong to more than one.
    static func caveAreas(from caves: [ChunkPosition: [String]]) -> [BiomeArea] {
        caveBiomeIDs.sorted().flatMap { biome in
            areas(from: caves.filter { $0.value.contains(biome) }.mapValues { _ in biome })
        }
    }

    /// Presents the shared index's areas as world-space paths. Every area is kept, down to a
    /// single chunk; names, colors and surface/cave membership remain presentation choices.
    static func areas(from biomes: [ChunkPosition: String]) -> [BiomeArea] {
        ChunkseeIndex.BiomeArea.connected(in: biomes).compactMap { area -> BiomeArea? in
            guard let origin = area.representative.blockOrigin else { return nil }
            var fill = Path(), outline = Path()
            for chunk in area.chunks {
                guard let origin = chunk.blockOrigin else { continue }
                fill.addRect(CGRect(x: origin.x, y: origin.z, width: 16, height: 16))
            }
            for edge in area.boundary {
                guard let origin = edge.chunk.blockOrigin else { continue }
                let x = CGFloat(origin.x), z = CGFloat(origin.z)
                let (from, to): (CGPoint, CGPoint) = switch edge.side {
                case .north: (CGPoint(x: x, y: z), CGPoint(x: x + 16, y: z))
                case .east: (CGPoint(x: x + 16, y: z), CGPoint(x: x + 16, y: z + 16))
                case .south: (CGPoint(x: x, y: z + 16), CGPoint(x: x + 16, y: z + 16))
                case .west: (CGPoint(x: x, y: z), CGPoint(x: x, y: z + 16))
                }
                outline.move(to: from)
                outline.addLine(to: to)
            }
            return BiomeArea(id: area.id, group: BiomeGroup(id: area.biomeID), chunkCount: area.chunkCount,
                             position: CGPoint(x: origin.x + 8, y: origin.z + 8), bounds: fill.boundingRect,
                             chunks: fill, outline: outline)
        }
    }
}
