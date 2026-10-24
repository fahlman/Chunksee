import ChunkseeKit
import CoreGraphics
import Foundation

/// Presentation over the renderer's already selected surface, never another block reader.
nonisolated enum MapShadow {
    struct Light: Hashable, Sendable {
        let x: Int, z: Int
        let rise: Double

        static let daylight = Light(x: -1, z: -1, rise: 1)

        /// Saved-time lighting travels east/west. Overhead or below-horizon lights cast no
        /// heightmap shadow; this does not invent another angle for an unavailable light.
        static func saved(_ direction: SIMD3<Float>) -> Light? {
            guard direction.x.isFinite, direction.y.isFinite, direction.z == 0,
                  direction.y >= 0, abs(direction.x) > 0.000001 else { return nil }
            return Light(x: direction.x < 0 ? -1 : 1, z: 0,
                         rise: Double(direction.y) / Double(abs(direction.x)))
        }
    }

    /// One region along the light ray bounds work and ensures each receiver has the same
    /// neighborhood on either side of a region boundary. Unknown columns never occlude.
    static let reach = RegionTileRenderer.side

    /// Retain both directions of the moving sun/moon, including while it is overhead. Fixed
    /// Daylight needs only its northwest neighbors; neither mode needs the southern row.
    static func retainedSources(for region: RegionPosition, savedTime: Bool) -> Set<RegionPosition> {
        savedTime ? RegionTileRenderer.neighboringRegions(around: region).filter { $0.z == region.z }
            : sources(for: region, light: .daylight)
    }

    static func sources(for region: RegionPosition, light: Light) -> Set<RegionPosition> {
        RegionTileRenderer.neighboringRegions(around: region).filter { other in
            (light.x == 0 ? other.x == region.x : light.x < 0 ? other.x <= region.x : other.x >= region.x)
                && (light.z == 0 ? other.z == region.z : light.z < 0 ? other.z <= region.z : other.z >= region.z)
        }
    }

    /// A monotone horizon queue visits each column once. Expiring the oldest entry gives a
    /// bounded ray without repeating a full ray march at every destination pixel.
    static func mask(for region: RegionPosition, heights: [RegionPosition: [Int32]], light: Light) throws -> [UInt8] {
        let side = RegionTileRenderer.side
        let width = light.x == 0 ? side : side * 2, height = light.z == 0 ? side : side * 2
        let originX = light.x < 0 ? -side : 0, originZ = light.z < 0 ? -side : 0
        let empty = RegionTileRenderer.Canvas.noHeight
        var field = [Int32](repeating: empty, count: width * height)
        for source in sources(for: region, light: light) {
            guard let values = heights[source], values.count == side * side else { continue }
            // sources() contains only checked adjacent regions, so these differences are ±1.
            let startX = (source.x - region.x) * side - originX
            let startZ = (source.z - region.z) * side - originZ
            for z in 0..<side {
                try Task.checkCancellation()
                let start = (startZ + z) * width + startX
                field.replaceSubrange(start..<(start + side), with: values[(z * side)..<((z + 1) * side)])
            }
        }
        var mask = [UInt8](repeating: 0, count: side * side)
        let dx = -light.x, dz = -light.z
        let startX = light.x > 0 ? width - 1 : 0, startZ = light.z > 0 ? height - 1 : 0
        var positions = [Int](repeating: 0, count: max(width, height))
        var horizons = [Double](repeating: 0, count: positions.count)

        func ray(x: Int, z: Int) throws {
            var x = x, z = z, distance = 0, first = 0, last = 0
            while (0..<width).contains(x), (0..<height).contains(z) {
                if distance % 128 == 0 { try Task.checkCancellation() }
                while first < last, positions[first] < distance - reach { first += 1 }
                let value = field[z * width + x]
                if value != empty {
                    let level = Double(value) + Double(distance) * light.rise
                    let localX = x + originX, localZ = z + originZ
                    if (0..<side).contains(localX), (0..<side).contains(localZ),
                       first < last, horizons[first] > level + 0.000001 {
                        mask[localZ * side + localX] = 255
                    }
                    while first < last, horizons[last - 1] <= level { last -= 1 }
                    positions[last] = distance
                    horizons[last] = level
                    last += 1
                }
                x += dx; z += dz; distance += 1
            }
        }
        if dx != 0 {
            for z in 0..<height { try ray(x: startX, z: z) }
        }
        if dz != 0 {
            for x in 0..<width where dx == 0 || x != startX { try ray(x: x, z: startZ) }
        }
        return mask
    }

    @concurrent
    static func image(for region: RegionPosition, heights: [RegionPosition: [Int32]], light: Light) async throws -> CGImage? {
        guard heights[region]?.count == RegionTileRenderer.side * RegionTileRenderer.side else { return nil }
        let mask = try mask(for: region, heights: heights, light: light)
        guard mask.contains(255) else { return nil }
        var bytes = [UInt8](repeating: 0, count: mask.count * 4)
        for i in mask.indices { bytes[i * 4 + 3] = mask[i] }
        return CGImage.rgba(bytes, width: RegionTileRenderer.side, height: RegionTileRenderer.side)
    }
}
