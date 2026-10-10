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
        var sections = ColorSections(chunk)
        let heightmap = chunk.heightmap("WORLD_SURFACE") ?? chunk.heightmap("MOTION_BLOCKING")
        return (0..<256).map { i in
            // The heightmap gives the first free block above the surface; without one, scan from the top.
            let startY = heightmap.map { $0[i] - 1 } ?? sections.topY
            return sections.topColumn(x: i % 16, z: i / 16, from: startY)
        }
    }

    /// The highest block the map should show in a column, and how deep the water above it is.
    struct Column: Equatable {
        var y: Int
        var color: MapColor
        var waterDepth: Int
    }

    /// A chunk's sections with map colors resolved per palette entry, the first time a column
    /// reaches that entry. Looking colors up by block ID for every block examined dominated
    /// rendering (string matching per block), while resolving every palette entry up front wastes
    /// work on underground blocks the map never shows. Resolving lazily is never more work than either.
    struct ColorSections {
        enum Entry: Equatable {
            case unresolved
            case clear
            case solid(MapColor)
            case water(MapColor)
        }

        struct Section {
            var y: Int
            var states: PalettedContainer<BlockState>
            var entries: [Entry]
        }

        private var sections: [Section]
        private let firstY: Int
        let minY: Int
        let topY: Int

        init(_ chunk: Chunk) {
            sections = chunk.sections.compactMap { section in
                section.blockStates.map {
                    Section(y: section.y, states: $0, entries: Array(repeating: .unresolved, count: $0.palette.count))
                }
            }
            firstY = sections.first?.y ?? 0
            minY = chunk.minSectionY * 16
            topY = ((sections.last?.y ?? 0) + 1) * 16 - 1
        }

        private func sectionIndex(forBlockY y: Int) -> Int? {
            let sy = y >> 4
            // Sections are normally contiguous, so try direct indexing first.
            let guess = sy - firstY
            if sections.indices.contains(guess), sections[guess].y == sy { return guess }
            return sections.firstIndex { $0.y == sy }
        }

        /// The map entry for the block at section-local x/z and absolute y, or `nil` with no section there.
        private mutating func entry(x: Int, y: Int, z: Int) -> Entry? {
            guard let s = sectionIndex(forBlockY: y) else { return nil }
            let p = sections[s].states.paletteIndex(at: (y & 15) << 8 | z << 4 | x)
            guard p < sections[s].entries.count else { return .clear }
            if sections[s].entries[p] == .unresolved {
                let id = sections[s].states.palette[p].id
                sections[s].entries[p] = switch BlockColors.color(for: id) {
                case nil: .clear
                case let color? where BlockColors.isWater(id): .water(color)
                case let color?: .solid(color)
                }
            }
            return sections[s].entries[p]
        }

        mutating func topColumn(x: Int, z: Int, from startY: Int) -> Column? {
            var y = min(startY, topY)
            while y >= minY {
                guard let s = sectionIndex(forBlockY: y) else {
                    y = (y >> 4) * 16 - 1  // no section stored here: skip it
                    continue
                }
                // A uniform section is one block throughout; if the map sees through it, skip it whole.
                if sections[s].states.isUniform, entry(x: x, y: y, z: z) == .clear {
                    y = sections[s].y * 16 - 1
                    continue
                }
                switch entry(x: x, y: y, z: z) {
                case .solid(let color)?:
                    return Column(y: y, color: color, waterDepth: 0)
                case .water(let color)?:
                    // Look through up to 32 blocks of water so depth can tint it.
                    var depth = 1
                    while depth < 32, y - depth >= minY, case .water? = entry(x: x, y: y - depth, z: z) {
                        depth += 1
                    }
                    return Column(y: y, color: color, waterDepth: depth)
                default:
                    y -= 1
                }
            }
            return nil
        }
    }

    static func baseColor(for column: Column) -> MapColor {
        guard column.waterDepth > 0 else { return column.color }
        // Shallow water is lighter, deep water darker.
        return column.color.shaded(1.15 - min(Double(column.waterDepth), 24) / 40)
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
