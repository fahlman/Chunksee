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

/// Native paths and labels for shared biome areas, with the app's existing cave-membership policy.
nonisolated enum BiomePresentation {
    /// Biomes that generate only underground.
    static let caveBiomeIDs: Set<String> = [
        "minecraft:deep_dark", "minecraft:lush_caves", "minecraft:dripstone_caves", "minecraft:sulfur_caves",
    ]

    /// Presents the shared index's areas as world-space paths. Every area is kept, down to a
    /// single chunk; names, colors and surface/cave membership remain presentation choices.
    static func areas(from biomes: [ChunkPosition: String]) -> [BiomeArea] {
        areas(from: ChunkseeIndex.BiomeArea.connected(in: biomes))
    }

    static func areas(from areas: [ChunkseeIndex.BiomeArea]) -> [BiomeArea] {
        areas.compactMap { area -> BiomeArea? in
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
