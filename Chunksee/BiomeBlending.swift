import ChunkseeKit

/// Optional display blending, matching the verified 26.3 client's default five-by-five square.
/// The reader still owns biome selection and color resolution. Missing neighbors stay unknown.
nonisolated enum BiomeBlending {
    static let radius = 2
    static let cacheKey = "blend2"

    /// Shares checked sample positions between preparation and averaging, without per-pixel arrays.
    @discardableResult
    static func forEachSample(at point: BlockPosition, _ visit: (BlockPosition) -> Void) -> Bool {
        guard let x = Int32(exactly: point.x), let z = Int32(exactly: point.z) else { return false }
        let minX = x.subtractingReportingOverflow(Int32(radius)), maxX = x.addingReportingOverflow(Int32(radius))
        let minZ = z.subtractingReportingOverflow(Int32(radius)), maxZ = z.addingReportingOverflow(Int32(radius))
        guard !minX.overflow, !maxX.overflow, !minZ.overflow, !maxZ.overflow else { return false }
        for z in minZ.partialValue...maxZ.partialValue {
            for x in minX.partialValue...maxX.partialValue {
                visit(BlockPosition(blockX: Int(x), blockY: point.y, blockZ: Int(z)))
            }
        }
        return true
    }

    /// The client averages RGB channels independently with integer division, at unchanged Y.
    static func color(at point: BlockPosition, sample: (BlockPosition) -> UInt32?) -> UInt32? {
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, known = true
        guard forEachSample(at: point, { position in
            guard let rgb = sample(position) else { known = false; return }
            red += (rgb >> 16) & 255
            green += (rgb >> 8) & 255
            blue += rgb & 255
        }), known else { return nil }
        let count = UInt32((radius * 2 + 1) * (radius * 2 + 1))
        return (red / count) << 16 | (green / count) << 8 | blue / count
    }
}
