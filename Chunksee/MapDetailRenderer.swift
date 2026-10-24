import ChunkseeKit
import CoreGraphics

/// Close-up pixels come from the cached surface, never from another block read. The map and
/// exports both use this compositor, retaining the ordinary tile behind unavailable textures.
nonisolated enum MapDetailRenderer {
    static let minimumScale: CGFloat = 8

    static func visibleChunks(in surface: MapSurfaceDetail.Surface, region: RegionPosition,
                              viewport: MapViewport, size: CGSize) -> [ChunkPosition] {
        guard viewport.scale >= minimumScale, let range = viewport.visibleChunkRange(in: size),
              region.blockOrigin != nil, let origin = region.chunkOrigin else { return [] }
        let minX = max(origin.x, range.xs.lowerBound), maxX = min(origin.x + 31, range.xs.upperBound)
        let minZ = max(origin.z, range.zs.lowerBound), maxZ = min(origin.z + 31, range.zs.upperBound)
        guard minX <= maxX, minZ <= maxZ else { return [] }
        var result: [ChunkPosition] = []
        for z in minZ...maxZ {
            for x in minX...maxX where surface.detail.chunks[(z - origin.z) * 32 + x - origin.x] != nil {
                result.append(ChunkPosition(x: x, z: z))
            }
        }
        return result
    }

    @concurrent
    static func render(_ chunk: ChunkPosition, surface: MapSurfaceDetail.Surface,
                       assets: GameAssetLibrary, heightScale: MapHeightScale?) async throws -> CGImage? {
        try Task.checkCancellation()
        let side = RegionTileRenderer.side
        guard surface.heights.count == side * side, let origin = chunk.blockOrigin,
              let materials = surface.detail.chunks[chunk.localZ * 32 + chunk.localX] else { return nil }
        let startX = chunk.localX * 16, startZ = chunk.localZ * 16
        let positions: [BlockPosition?] = (0..<256).map { i in
            let height = surface.heights[(startZ + i / 16) * side + startX + i % 16]
            guard height != RegionTileRenderer.Canvas.noHeight else { return nil }
            return BlockPosition(blockX: origin.x + i % 16, blockY: Int(height), blockZ: origin.z + i / 16)
        }
        let textures = try await assets.mapTextures(requests: materials.materials.map(\.request),
                                                     indices: materials.indices, positions: positions)
        let texels = GameModelRenderer.blockTextureSide, imageSide = 16 * texels
        var pixels = [UInt8](repeating: 0, count: imageSide * imageSide * 4), hasPixels = false
        let lighting = MapRelief(heightScale: heightScale)
        for (i, texture) in textures.enumerated() {
            try Task.checkCancellation()
            guard let texture, texture.width == texels, texture.height == texels,
                  texture.pixels.count == texels * texels * 4 else { continue }
            let material = materials.materials[Int(materials.indices[i])]
            let index = (startZ + i / 16) * side + startX + i % 16
            let light = lighting.factor(at: index, heights: surface.heights, side: side)
            for y in 0..<texels {
                for x in 0..<texels {
                    let source = (y * texels + x) * 4, alpha = UInt32(texture.pixels[source + 3])
                    guard alpha > 0 else { continue }
                    // Shade straight color, then premultiply again. Bright slopes must never
                    // produce RGB greater than alpha around partially transparent plant edges.
                    func straight(_ channel: Int) -> UInt32 { min(255, (UInt32(texture.pixels[source + channel]) * 255 + alpha / 2) / alpha) }
                    let color = MapColor(straight(0) << 16 | straight(1) << 8 | straight(2)).shaded(material.colorShade)
                    let shaded = material.emphasis.applying(to: color).shaded(light)
                    let target = ((i / 16 * texels + y) * imageSide + i % 16 * texels + x) * 4
                    pixels[target] = UInt8((UInt32(shaded.red) * alpha + 127) / 255)
                    pixels[target + 1] = UInt8((UInt32(shaded.green) * alpha + 127) / 255)
                    pixels[target + 2] = UInt8((UInt32(shaded.blue) * alpha + 127) / 255)
                    pixels[target + 3] = UInt8(alpha)
                    hasPixels = true
                }
            }
        }
        try Task.checkCancellation()
        return hasPixels ? CGImage.rgba(pixels, width: imageSide, height: imageSide) : nil
    }
}
