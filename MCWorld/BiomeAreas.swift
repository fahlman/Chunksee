import CoreGraphics
import Foundation
import MCWorldKit

/// A biome, as a sidebar group.
nonisolated struct BiomeGroup: MapLayerGroup, Sendable {
    var id: String
    var name: String { ReadableName.from(id) }
    var symbol: String { "leaf" }
}

/// A patch of neighboring chunks whose surface is the same biome.
nonisolated struct BiomeArea: MapLayerMarker, Sendable {
    var id: String
    var group: BiomeGroup
    var chunkCount: Int
    /// The center of the area's chunk nearest its middle, so it lies inside the area.
    var position: CGPoint
    var name: String { String(localized: "\(chunkCount) chunks") }
}

/// Finds biome areas by sampling one surface column per chunk and joining neighboring chunks of
/// the same biome.
nonisolated enum BiomeScanner {
    /// Areas smaller than this are slivers along borders, not places worth visiting.
    static let minimumChunks = 4

    @concurrent
    static func scan(_ dimension: MCWorldKit.Dimension) async -> [BiomeArea] {
        let biomes = await withTaskGroup(of: [ChunkCoordinate: String].self) { group in
            for region in dimension.regionFiles() {
                group.addTask {
                    guard !Task.isCancelled, let file = try? dimension.region(x: region.x, z: region.z) else { return [:] }
                    var found: [ChunkCoordinate: String] = [:]
                    for (x, z) in file.chunkCoordinates {
                        guard let nbt = try? file.chunkNBT(localX: x, localZ: z, skipping: Chunk.keysNotNeededForTerrain),
                              let chunk = try? Chunk(nbt: nbt), let biome = surfaceBiome(of: chunk, in: dimension.id) else { continue }
                        found[ChunkCoordinate(x: region.x * 32 + x, z: region.z * 32 + z)] = biome
                    }
                    return found
                }
            }
            var all: [ChunkCoordinate: String] = [:]
            for await found in group { all.merge(found) { $1 } }
            return all
        }
        return areas(from: biomes)
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
            areas.append(BiomeArea(id: "\(biome)@\(inside.x),\(inside.z)", group: BiomeGroup(id: biome), chunkCount: chunks.count,
                                   position: CGPoint(x: inside.x * 16 + 8, y: inside.z * 16 + 8)))
        }
        return areas
    }
}

nonisolated struct ChunkCoordinate: Hashable, Sendable {
    var x: Int
    var z: Int
}
