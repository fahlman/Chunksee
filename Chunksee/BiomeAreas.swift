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
    /// Areas smaller than this are slivers along borders, not places worth visiting.
    static let minimumChunks = 4
    /// Biomes that generate only underground.
    static let caveBiomeIDs: Set<String> = ["minecraft:deep_dark", "minecraft:lush_caves", "minecraft:dripstone_caves"]

    @concurrent
    static func scan(_ reader: RegionReader) async -> BiomeScan {
        var scan = BiomeScan()
        for part in await reader.everyRegion({ await ($0.biomes($1), $0.caveBiomes($1)) }) {
            scan.biomes.merge(part.value.0) { $1 }
            scan.caveBiomes.merge(part.value.1) { $1 }
        }
        scan.areas = areas(from: scan.biomes) + caveAreas(from: scan.caveBiomes)
        return scan
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

    /// Joins chunks of the same biome that share an edge.
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
            guard chunks.count >= minimumChunks else { continue }
            let middleX = Double(chunks.map(\.x).reduce(0, +)) / Double(chunks.count)
            let middleZ = Double(chunks.map(\.z).reduce(0, +)) / Double(chunks.count)
            let inside = chunks.min { hypot(Double($0.x) - middleX, Double($0.z) - middleZ) < hypot(Double($1.x) - middleX, Double($1.z) - middleZ) }!
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
