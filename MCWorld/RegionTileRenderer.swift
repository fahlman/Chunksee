import CoreGraphics
import Foundation
import MCWorldKit

/// Renders one region (512×512 blocks) of a dimension as a top-down image, one pixel per block.
///
/// Rendering reads and decodes up to 1,024 chunks, so it runs off the main actor and checks for
/// cancellation between chunks. With `chunkConcurrency` above 1, chunks decode in parallel.
nonisolated struct RegionTileRenderer: Sendable {
    static let side = RegionCoordinate.blockSize

    let dimension: MCWorldKit.Dimension
    /// How many chunks of one region decode at the same time.
    var chunkConcurrency = 1

    /// RGBA pixels (premultiplied, row-major, 512×512), or `nil` when the region file doesn't exist.
    /// Columns in ungenerated chunks stay fully transparent.
    func pixels(for region: RegionCoordinate) async throws -> [UInt8]? {
        guard let file = try dimension.region(x: region.x, z: region.z) else { return nil }
        let coordinates = file.chunkCoordinates
        var canvas = Canvas()
        if chunkConcurrency <= 1 {
            for (localX, localZ) in coordinates {
                try Task.checkCancellation()
                if let columns = Self.columns(in: file, localX: localX, localZ: localZ) {
                    canvas.set(columns, chunkX: localX, chunkZ: localZ)
                }
            }
        } else {
            try await withThrowingTaskGroup(of: (Int, Int, [Column?])?.self) { group in
                var next = coordinates.startIndex
                func startNext() {
                    guard next < coordinates.endIndex else { return }
                    let (localX, localZ) = coordinates[next]
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return Self.columns(in: file, localX: localX, localZ: localZ).map { (localX, localZ, $0) }
                    }
                }
                for _ in 0..<chunkConcurrency { startNext() }
                for try await result in group {
                    if let (localX, localZ, columns) = result { canvas.set(columns, chunkX: localX, chunkZ: localZ) }
                    startNext()
                }
            }
        }
        canvas.applyRelief()
        return canvas.pixels
    }

    func image(for region: RegionCoordinate) async throws -> CGImage? {
        try await pixels(for: region).flatMap(Self.makeImage)
    }

    /// The 256 top columns of one chunk (index `z * 16 + x`), or `nil` when it can't be decoded.
    /// One damaged chunk shouldn't blank the whole region; it's left transparent instead.
    static func columns(in file: RegionFile, localX: Int, localZ: Int) -> [Column?]? {
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        let heightmap = chunk.heightmap("WORLD_SURFACE") ?? chunk.heightmap("MOTION_BLOCKING")
        return (0..<256).map { topColumn(in: chunk, x: $0 % 16, z: $0 / 16, heightmap: heightmap) }
    }

    /// The highest block the map should show in a column, and how deep the water above it is.
    struct Column: Equatable {
        var y: Int
        var block: BlockState
        var waterDepth: Int
    }

    static func topColumn(in chunk: Chunk, x: Int, z: Int, heightmap: [Int]?) -> Column? {
        let minY = chunk.minSectionY * 16
        guard let topSection = chunk.sections.last else { return nil }
        // The heightmap gives the first free block above the surface; without one, scan from the top.
        var y = (heightmap?[z * 16 + x] ?? (topSection.y * 16 + 16)) - 1
        while y >= minY {
            if let block = chunk.block(x: x, y: y, z: z), BlockColors.color(for: block.id) != nil {
                break
            }
            y -= 1
        }
        guard y >= minY, var block = chunk.block(x: x, y: y, z: z) else { return nil }

        // Look through up to 32 blocks of water so depth can tint it.
        var depth = 0
        let surfaceY = y
        while BlockColors.isWater(block.id), depth < 32, y > minY {
            y -= 1
            depth += 1
            guard let below = chunk.block(x: x, y: y, z: z) else { break }
            block = below
        }
        if depth > 0 { return Column(y: surfaceY, block: BlockState("minecraft:water"), waterDepth: depth) }
        return Column(y: y, block: block, waterDepth: 0)
    }

    static func baseColor(for column: Column) -> MapColor {
        let base = BlockColors.color(for: column.block.id) ?? MapColor(0x000000)
        guard column.waterDepth > 0 else { return base }
        // Shallow water is lighter, deep water darker.
        return base.shaded(1.15 - min(Double(column.waterDepth), 24) / 40)
    }

    /// Pixels plus the surface height of each column, kept so relief shading can compare
    /// neighbors across chunk edges after every chunk is drawn.
    struct Canvas {
        static let noHeight = Int32.min

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var heights = [Int32](repeating: noHeight, count: side * side)
        var isWater = [Bool](repeating: false, count: side * side)

        mutating func set(x: Int, z: Int, column: Column) {
            let i = z * side + x
            let color = baseColor(for: column)
            pixels[i * 4] = color.red
            pixels[i * 4 + 1] = color.green
            pixels[i * 4 + 2] = color.blue
            pixels[i * 4 + 3] = 255
            heights[i] = Int32(column.y)
            isWater[i] = column.waterDepth > 0
        }

        mutating func set(_ columns: [Column?], chunkX: Int, chunkZ: Int) {
            for (i, column) in columns.enumerated() {
                if let column { set(x: chunkX * 16 + i % 16, z: chunkZ * 16 + i / 16, column: column) }
            }
        }

        /// Lightens land that is higher than the block to its north and darkens land that is lower.
        mutating func applyRelief() {
            for z in stride(from: side - 1, through: 1, by: -1) {
                for x in 0..<side {
                    let i = z * side + x, north = heights[i - side]
                    guard heights[i] != Self.noHeight, north != Self.noHeight, !isWater[i] else { continue }
                    let factor: Double = heights[i] > north ? 1.12 : heights[i] < north ? 0.85 : 1
                    guard factor != 1 else { continue }
                    let shaded = MapColor(UInt32(pixels[i * 4]) << 16 | UInt32(pixels[i * 4 + 1]) << 8
                                          | UInt32(pixels[i * 4 + 2])).shaded(factor)
                    pixels[i * 4] = shaded.red
                    pixels[i * 4 + 1] = shaded.green
                    pixels[i * 4 + 2] = shaded.blue
                }
            }
        }
    }

    static func makeImage(_ pixels: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
