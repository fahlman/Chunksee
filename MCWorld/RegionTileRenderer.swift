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
        try await pixels(for: region).flatMap { Self.makeImage($0, side: Self.side) }
    }

    /// A region's full-resolution image and a half-resolution preview for zoomed-out views.
    struct RenderedTile: @unchecked Sendable {  // CGImage is immutable.
        var full: CGImage
        var preview: CGImage
    }

    static let previewSide = side / 2

    func tile(for region: RegionCoordinate) async throws -> RenderedTile? {
        guard let pixels = try await pixels(for: region),
              let full = Self.makeImage(pixels, side: Self.side),
              let preview = Self.makeImage(Self.halfSize(pixels), side: Self.previewSide) else { return nil }
        return RenderedTile(full: full, preview: preview)
    }

    /// Averages each 2×2 block of premultiplied RGBA pixels, so partly generated edges fade
    /// rather than alias.
    static func halfSize(_ pixels: [UInt8]) -> [UInt8] {
        let half = side / 2
        var out = [UInt8](repeating: 0, count: half * half * 4)
        for z in 0..<half {
            for x in 0..<half {
                let a = ((2 * z) * side + 2 * x) * 4, b = a + side * 4
                for c in 0..<4 {
                    let sum = Int(pixels[a + c]) + Int(pixels[a + 4 + c]) + Int(pixels[b + c]) + Int(pixels[b + 4 + c])
                    out[(z * half + x) * 4 + c] = UInt8((sum + 2) / 4)
                }
            }
        }
        return out
    }

    /// The 256 top columns of one chunk (index `z * 16 + x`), or `nil` when it can't be decoded.
    /// One damaged chunk shouldn't blank the whole region; it's left transparent instead.
    static func columns(in file: RegionFile, localX: Int, localZ: Int) -> [Column?]? {
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        var sections = ColorSections(chunk)
        // The heightmap gives the first free block above the surface; without one (most chunks
        // upgraded from old versions have none), every column starts at the top of the chunk.
        let heightmap = chunk.heightmap("WORLD_SURFACE") ?? chunk.heightmap("MOTION_BLOCKING")
        let topY = sections.topY
        return sections.topColumns { i in heightmap.map { $0[i] - 1 } ?? topY }
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
        let minY: Int
        let topY: Int

        init(_ chunk: Chunk) {
            sections = chunk.sections.compactMap { section in
                section.blockStates.map {
                    Section(y: section.y, states: $0, entries: Array(repeating: .unresolved, count: $0.palette.count))
                }
            }
            minY = chunk.minSectionY * 16
            topY = ((sections.last?.y ?? 0) + 1) * 16 - 1
        }

        private mutating func resolve(section s: Int, palette p: Int) -> Entry {
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

        /// The top column for each of the 256 columns (index `z * 16 + x`), scanning down from
        /// `startY(i)`. Sections are visited top-down and each one's palette indices are decoded in
        /// one sequential pass, so all columns advance together instead of each column doing
        /// hundreds of random lookups; the scan stops as soon as every column is resolved.
        mutating func topColumns(startY: (Int) -> Int) -> [Column?] {
            enum State { case searching, water, done }
            var result = [Column?](repeating: nil, count: 256)
            var state = [State](repeating: .searching, count: 256)
            let start = (0..<256).map { min(startY($0), topY) }
            var waterY = [Int](repeating: 0, count: 256)
            var waterColor = [MapColor](repeating: MapColor(0), count: 256)
            var depth = [Int](repeating: 0, count: 256)
            var remaining = 256

            func finishWater(_ i: Int) {
                result[i] = Column(y: waterY[i], color: waterColor[i], waterDepth: depth[i])
                state[i] = .done
                remaining -= 1
            }

            var previousSectionY: Int?
            for s in sections.indices.reversed() where remaining > 0 {
                let sectionY = sections[s].y
                let low = sectionY * 16
                // Water depth stops at a gap in the stored sections.
                if let previousSectionY, previousSectionY != sectionY + 1 {
                    for i in 0..<256 where state[i] == .water { finishWater(i) }
                }
                previousSectionY = sectionY
                guard remaining > 0, low >= minY - 15 else { break }
                // Skip sections that every still-searching column starts below.
                guard (0..<256).contains(where: { state[$0] == .water || (state[$0] == .searching && start[$0] >= low) }) else {
                    continue
                }

                let uniform = sections[s].states.isUniform
                let indices = uniform ? [] : sections[s].states.allPaletteIndices()
                if uniform, resolve(section: s, palette: 0) == .clear {
                    for i in 0..<256 where state[i] == .water { finishWater(i) }
                    continue
                }
                for y in stride(from: 15, through: 0, by: -1) where remaining > 0 {
                    let absoluteY = low + y
                    guard absoluteY >= minY else { break }
                    for i in 0..<256 {
                        switch state[i] {
                        case .done:
                            continue
                        case .searching:
                            guard absoluteY <= start[i] else { continue }
                            switch resolve(section: s, palette: uniform ? 0 : indices[y << 8 | i]) {
                            case .solid(let color):
                                result[i] = Column(y: absoluteY, color: color, waterDepth: 0)
                                state[i] = .done
                                remaining -= 1
                            case .water(let color):
                                state[i] = .water
                                waterY[i] = absoluteY
                                waterColor[i] = color
                                depth[i] = 1
                                if depth[i] >= 32 { finishWater(i) }
                            default:
                                continue
                            }
                        case .water:
                            if case .water = resolve(section: s, palette: uniform ? 0 : indices[y << 8 | i]) {
                                depth[i] += 1
                                if depth[i] >= 32 { finishWater(i) }
                            } else {
                                finishWater(i)
                            }
                        }
                    }
                }
            }
            for i in 0..<256 where state[i] == .water { finishWater(i) }
            return result
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

    static func makeImage(_ pixels: [UInt8], side: Int = side) -> CGImage? {
        guard pixels.count == side * side * 4, let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
