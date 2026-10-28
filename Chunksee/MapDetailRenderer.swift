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
                       assets: GameArtworkLibrary, heightScale: MapHeightScale?, usesSavedLighting: Bool) async throws -> MapTileImage? {
        try Task.checkCancellation()
        let side = RegionTileRenderer.side
        guard surface.heights.count == side * side,
              surface.nightLight == nil || surface.nightLight?.count == side * side,
              let origin = chunk.blockOrigin,
              let materials = surface.detail.chunks[chunk.localZ * 32 + chunk.localX] else { return nil }
        let startX = chunk.localX * 16, startZ = chunk.localZ * 16
        var positions: [BlockPosition?] = (0..<256).map { i in
            let height = surface.heights[(startZ + i / 16) * side + startX + i % 16]
            guard height != RegionTileRenderer.Canvas.noHeight else { return nil }
            return BlockPosition(blockX: origin.x + i % 16, blockY: Int(height), blockZ: origin.z + i / 16)
        }
        var indices = materials.indices
        var overlays = [MapSurfaceDetail.Chunk.Overlay?](repeating: nil, count: 256)
        var layerRanges = [Range<Int>](repeating: 0..<0, count: 256)
        for overlay in materials.overlays {
            let i = Int(overlay.column), start = indices.count
            overlays[i] = overlay
            for layer in overlay.layers.reversed() {
                indices.append(layer.material)
                positions.append(BlockPosition(blockX: origin.x + i % 16, blockY: Int(layer.y), blockZ: origin.z + i / 16))
            }
            layerRanges[i] = start..<indices.count
        }
        let textures = try await assets.mapTextures(requests: materials.materials.map(\.request),
                                                     indices: indices, positions: positions)
        guard textures.count == positions.count else { return nil }
        let texels = GameModelRenderer.blockTextureSide, imageSide = 16 * texels
        var pixels = [UInt8](repeating: 0, count: imageSide * imageSide * 4), hasPixels = false
        // Normals still have one pixel per block; the shared shader samples them by location,
        // so sixteen-times larger texture pictures do not need sixteen-times larger normals.
        var normals = usesSavedLighting ? [UInt8](repeating: 0, count: 16 * 16 * 4) : nil
        let lighting = MapRelief(heightScale: heightScale, directionalStrength: usesSavedLighting ? 0.25 : 1)
        for i in 0..<256 {
            try Task.checkCancellation()
            guard textures[i] != nil || overlays[i] != nil else { continue }
            let index = (startZ + i / 16) * side + startX + i % 16
            let slope = MapRelief.slope(at: index, heights: surface.heights, side: side)
            let isWater = overlays[i]?.isWater == true
            let light = isWater ? 1 : lighting.factor(height: surface.heights[index], north: slope.north, west: slope.west)
            if usesSavedLighting {
                RegionTileRenderer.encodeNormal(isWater ? SIMD3(0, 0, 1) : slope.normal, into: &normals!, at: i * 4)
                normals![i * 4 + 3] = 255
            }
            let night = surface.nightLight.flatMap { DarkSpots.Status(rawValue: $0[index]) }
            func shade(_ color: MapColor, emphasis: MapBlockFilter.Emphasis) -> MapColor {
                let shaded = emphasis.applying(to: color).shaded(light)
                return night.map { DarkSpots.color(shaded, status: $0, x: index % side, z: index / side) } ?? shaded
            }
            func target(_ x: Int, _ y: Int) -> Int {
                ((i / 16 * texels + y) * imageSide + i % 16 * texels + x) * 4
            }
            if let overlay = overlays[i], let top = overlay.layers.first {
                let color = shade(MapColor(overlay.baseColor), emphasis: materials.materials[Int(top.material)].emphasis)
                for y in 0..<texels {
                    for x in 0..<texels {
                        let t = target(x, y)
                        pixels[t] = color.red; pixels[t + 1] = color.green; pixels[t + 2] = color.blue; pixels[t + 3] = 255
                    }
                }
                hasPixels = true
            }
            func draw(_ textureIndex: Int) {
                guard let texture = textures[textureIndex], texture.width == texels, texture.height == texels,
                      texture.pixels.count == texels * texels * 4 else { return }
                let material = materials.materials[Int(indices[textureIndex])]
                for y in 0..<texels {
                    for x in 0..<texels {
                        let source = (y * texels + x) * 4, alpha = UInt32(texture.pixels[source + 3])
                        guard alpha > 0 else { continue }
                        // Shade straight color, then composite premultiplied pixels over the
                        // retained ground and lower layers, never over the averaged top color.
                        func straight(_ channel: Int) -> UInt32 { min(255, (UInt32(texture.pixels[source + channel]) * 255 + alpha / 2) / alpha) }
                        let color = MapColor(straight(0) << 16 | straight(1) << 8 | straight(2)).shaded(material.colorShade)
                        let shaded = shade(color, emphasis: material.emphasis), t = target(x, y)
                        pixels[t] = UInt8((UInt32(shaded.red) * alpha + UInt32(pixels[t]) * (255 - alpha) + 127) / 255)
                        pixels[t + 1] = UInt8((UInt32(shaded.green) * alpha + UInt32(pixels[t + 1]) * (255 - alpha) + 127) / 255)
                        pixels[t + 2] = UInt8((UInt32(shaded.blue) * alpha + UInt32(pixels[t + 2]) * (255 - alpha) + 127) / 255)
                        pixels[t + 3] = UInt8(alpha + (UInt32(pixels[t + 3]) * (255 - alpha) + 127) / 255)
                        hasPixels = true
                    }
                }
            }
            draw(i)
            for textureIndex in layerRanges[i] { draw(textureIndex) }
        }
        try Task.checkCancellation()
        guard hasPixels, let image = CGImage.rgba(pixels, width: imageSide, height: imageSide) else { return nil }
        let normalImage = normals.flatMap { CGImage.rgba($0, width: 16, height: 16, colorSpace: CGColorSpace.linearSRGB) }
        guard !usesSavedLighting || normalImage != nil else { return nil }
        return MapTileImage(image, normals: normalImage)
    }
}
