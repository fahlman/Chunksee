import Foundation
import ChunkseeKit
import SwiftUI

/// A biome, as a sidebar group.
nonisolated struct BiomeGroup: MapLayerGroup, Sendable {
    var id: String
    var name: String { ReadableName.from(id) }
    var symbol: String { "leaf" }
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
    var searchText: String { group.name + " " + group.id }
}

/// Biome areas, and every sampled chunk's biomes for the hover readout.
nonisolated struct BiomeScan: Sendable {
    var areas: [BiomeArea] = []
    var biomes: [ChunkCoordinate: String] = [:]
    /// Cave biomes under each chunk that has any.
    var caveBiomes: [ChunkCoordinate: [String]] = [:]
}

/// Finds biome areas by sampling one surface column per chunk and joining neighboring chunks of
/// the same biome. Cave biomes never reach the surface, so each chunk's sections are also checked
/// for them, and their areas are found the same way.
nonisolated enum BiomeScanner {
    /// Biomes that generate only underground.
    static let caveBiomeIDs: Set<String> = [
        "minecraft:deep_dark", "minecraft:lush_caves", "minecraft:dripstone_caves", "minecraft:sulfur_caves",
    ]

    @concurrent
    static func scan(_ reader: RegionReader) async -> BiomeScan {
        var scan = BiomeScan()
        for part in await reader.everyRegion({ await ($0.biomes($1), $0.caveBiomes($1)) }) {
            scan.biomes.merge(part.value.0) { $1 }
            scan.caveBiomes.merge(part.value.1) { $1 }
        }
        scan.areas = areas(surface: scan.biomes, caves: scan.caveBiomes)
        return scan
    }

    /// Every biome's areas, each chunk counted once per biome. A cave biome sometimes reaches the
    /// surface sample, but its underground membership already covers that chunk, so its areas come
    /// only from there; the hover readout still names the surface biome.
    static func areas(surface: [ChunkCoordinate: String], caves: [ChunkCoordinate: [String]]) -> [BiomeArea] {
        areas(from: surface.filter { !caveBiomeIDs.contains($0.value) }) + caveAreas(from: caves)
    }

    /// The cave biomes anywhere in a chunk, from its sections' biome palettes.
    static func caveBiomes(of chunk: Chunk) -> [String] {
        Set(chunk.sections.flatMap { $0.biomes?.palette ?? [] }).intersection(caveBiomeIDs).sorted()
    }

    /// Areas of each cave biome; a chunk can belong to more than one.
    static func caveAreas(from caves: [ChunkCoordinate: [String]]) -> [BiomeArea] {
        caveBiomeIDs.sorted().flatMap { biome in
            areas(from: caves.filter { $0.value.contains(biome) }.mapValues { _ in biome })
        }
    }

    /// The biome at the middle column's surface: the heightmap's top block, or the top of the
    /// highest section with blocks when the chunk has no heightmap. The Nether's surface is under
    /// its roof, so it's sampled at Y 64.
    static func surfaceBiome(of chunk: Chunk, in dimension: String) -> String? {
        let y: Int
        if dimension == "minecraft:the_nether" {
            y = 64
        } else if let heights = chunk.heightmap("WORLD_SURFACE") {
            y = heights[8 * 16 + 8] - 1
        } else if let top = chunk.sections.last(where: { $0.blockStates?.palette.contains { !$0.id.hasSuffix("air") } == true }) {
            y = top.y * 16 + 15
        } else {
            return nil
        }
        return chunk.biome(x: 8, y: y, z: 8)
    }

    /// Joins chunks of the same biome that share an edge. Every area is kept, down to a single
    /// chunk, so nothing in the world is hidden (Ryan, 2026-10-13); one sample per chunk breaks
    /// thin biomes such as rivers and beaches into many small areas.
    static func areas(from biomes: [ChunkCoordinate: String]) -> [BiomeArea] {
        var visited = Set<ChunkCoordinate>()
        var areas: [BiomeArea] = []
        for (start, biome) in biomes where !visited.contains(start) {
            var chunks: [ChunkCoordinate] = []
            var stack = [start]
            visited.insert(start)
            while let chunk = stack.popLast() {
                chunks.append(chunk)
                for next in [ChunkCoordinate(x: chunk.x + 1, z: chunk.z), ChunkCoordinate(x: chunk.x - 1, z: chunk.z),
                             ChunkCoordinate(x: chunk.x, z: chunk.z + 1), ChunkCoordinate(x: chunk.x, z: chunk.z - 1)]
                where !visited.contains(next) && biomes[next] == biome {
                    visited.insert(next)
                    stack.append(next)
                }
            }
            let middleX = Double(chunks.map(\.x).reduce(0, +)) / Double(chunks.count)
            let middleZ = Double(chunks.map(\.z).reduce(0, +)) / Double(chunks.count)
            let inside = chunks.min {
                let a = hypot(Double($0.x) - middleX, Double($0.z) - middleZ)
                let b = hypot(Double($1.x) - middleX, Double($1.z) - middleZ)
                return a == b ? ($0.x, $0.z) < ($1.x, $1.z) : a < b
            }!
            // Outline the edges between this area's chunks and anything else.
            var fill = Path(), outline = Path()
            let members = Set(chunks)
            for chunk in chunks {
                let x = CGFloat(chunk.x * 16), z = CGFloat(chunk.z * 16)
                fill.addRect(CGRect(x: x, y: z, width: 16, height: 16))
                for (dx, dz, from, to) in [(0, -1, (0, 0), (16, 0)), (1, 0, (16, 0), (16, 16)), (0, 1, (0, 16), (16, 16)), (-1, 0, (0, 0), (0, 16))]
                where !members.contains(ChunkCoordinate(x: chunk.x + dx, z: chunk.z + dz)) {
                    outline.move(to: CGPoint(x: x + CGFloat(from.0), y: z + CGFloat(from.1)))
                    outline.addLine(to: CGPoint(x: x + CGFloat(to.0), y: z + CGFloat(to.1)))
                }
            }
            areas.append(BiomeArea(id: "\(biome)@\(inside.x),\(inside.z)", group: BiomeGroup(id: biome), chunkCount: chunks.count,
                                   position: CGPoint(x: inside.x * 16 + 8, y: inside.z * 16 + 8), bounds: fill.boundingRect,
                                   chunks: fill, outline: outline))
        }
        return areas
    }
}

nonisolated struct ChunkCoordinate: Hashable, Sendable, Codable {
    var x: Int
    var z: Int
}
