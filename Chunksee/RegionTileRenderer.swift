import CoreGraphics
import Foundation
import ChunkseeKit

/// Renders one region (512×512 blocks) of a dimension as a top-down image, one pixel per block.
///
/// Rendering reads and decodes up to 1,024 chunks, so it runs off the main actor and checks for
/// cancellation between chunks. With `chunkConcurrency` above 1, chunks decode in parallel.
nonisolated struct RegionTileRenderer: Sendable {
    static let side = RegionCoordinate.blockSize

    let dimension: ChunkseeKit.Dimension
    /// How many chunks of one region decode at the same time.
    var chunkConcurrency = 1
    /// Rendered pixels saved between launches; `nil` renders every time.
    var cache: TileCache?
    /// Saving compresses and writes about 1 MB, so by default it happens after the tile is
    /// returned, at low priority, keeping it off the path to the screen. Tests save synchronously.
    var savesInBackground = true

    /// RGBA pixels (premultiplied, row-major, 512×512), or `nil` when the region file doesn't exist.
    /// Columns in ungenerated chunks stay fully transparent.
    @concurrent
    func pixels(for region: RegionCoordinate) async throws -> [UInt8]? {
        guard let file = try dimension.region(x: region.x, z: region.z) else { return nil }
        let coordinates = file.chunkCoordinates
        var canvas = Canvas()
        if chunkConcurrency <= 1 {
            for (localX, localZ) in coordinates {
                try Task.checkCancellation()
                if let columns = Self.columns(in: file, localX: localX, localZ: localZ, ceilingY: ceilingY) {
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
                        return Self.columns(in: file, localX: localX, localZ: localZ, ceilingY: ceilingY).map { (localX, localZ, $0) }
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

    @concurrent
    func image(for region: RegionCoordinate) async throws -> CGImage? {
        try await pixels(for: region).flatMap { Self.makeImage($0, side: Self.side) }
    }

    /// A region's full-resolution image and a half-resolution preview for zoomed-out views.
    struct RenderedTile: @unchecked Sendable {  // CGImage is immutable.
        var full: CGImage
        var preview: CGImage
    }

    static let previewSide = side / 2

    /// Runs off the caller's actor: with approachable concurrency a plain nonisolated `async`
    /// method would otherwise run on the main actor when called from the map model.
    @concurrent
    func tile(for region: RegionCoordinate) async throws -> RenderedTile? {
        // The key is taken before rendering, so a file changed mid-render is re-rendered next time.
        let regionFile = dimension.regionDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca")
        let key = cache == nil ? nil : TileCache.key(for: region, regionFile: regionFile)
        var pixels: [UInt8]?
        if let cache, let key, let cached = cache.load(key) {
            pixels = cached
        } else {
            pixels = try await self.pixels(for: region)
            if let cache, let key, let pixels {
                if savesInBackground {
                    Task.detached(priority: .utility) { cache.store(pixels, for: key) }
                } else {
                    cache.store(pixels, for: key)
                }
            }
        }
        guard let pixels,
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

    /// The highest block under a dimension's roof, for dimensions that have one.
    var ceilingY: Int? { dimension.id == "minecraft:the_nether" ? 127 : nil }

    /// The 256 top columns of one chunk (index `z * 16 + x`), or `nil` when it can't be decoded.
    /// One damaged chunk shouldn't blank the whole region; it's left transparent instead.
    static func columns(in file: RegionFile, localX: Int, localZ: Int, ceilingY: Int? = nil) -> [Column?]? {
        // The map needs only blocks and heightmaps; skipping ticks, light and the like is faster.
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ, skipping: Chunk.keysNotNeededForTerrain),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        var sections = ColorSections(chunk)
        // The heightmap gives the first free block above the surface; without one (most chunks
        // upgraded from old versions have none), every column starts at the top of the chunk.
        let heightmap = chunk.heightmap("WORLD_SURFACE") ?? chunk.heightmap("MOTION_BLOCKING")
        let topY = sections.topY
        if let ceilingY {
            return sections.topColumns(underCeiling: true) { _ in ceilingY }
        }
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
        /// With `underCeiling`, each column first steps down through solid blocks until it reaches
        /// open space, then searches as usual: the Nether's bedrock roof would otherwise hide everything.
        mutating func topColumns(underCeiling: Bool = false, startY: (Int) -> Int) -> [Column?] {
            enum State { case ceiling, searching, water, done }
            var result = [Column?](repeating: nil, count: 256)
            var state = [State](repeating: underCeiling ? .ceiling : .searching, count: 256)
            let start = (0..<256).map { min(startY($0), topY) }
            var waterY = [Int](repeating: 0, count: 256)
            var waterColor = [MapColor](repeating: MapColor(0), count: 256)
            var depth = [Int](repeating: 0, count: 256)
            var remaining = 256
            // Under a ceiling, the first solid block below the roof's bedrock band (at most five
            // blocks thick in the Nether), drawn darkened if a column never reaches open space
            // (solid rock all the way down) instead of leaving a hole.
            var ceilingFallback = [Column?](repeating: nil, count: 256)

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
                guard (0..<256).contains(where: {
                    state[$0] == .water || ((state[$0] == .searching || state[$0] == .ceiling) && start[$0] >= low)
                }) else {
                    continue
                }

                let uniform = sections[s].states.isUniform
                let indices = uniform ? [] : sections[s].states.allPaletteIndices()
                if uniform, resolve(section: s, palette: 0) == .clear {
                    for i in 0..<256 where state[i] == .water { finishWater(i) }
                    // An open section below a ceiling: those columns now search for the floor.
                    for i in 0..<256 where state[i] == .ceiling && start[i] >= low { state[i] = .searching }
                    continue
                }
                for y in stride(from: 15, through: 0, by: -1) where remaining > 0 {
                    let absoluteY = low + y
                    guard absoluteY >= minY else { break }
                    for i in 0..<256 {
                        switch state[i] {
                        case .done:
                            continue
                        case .ceiling:
                            guard absoluteY <= start[i] else { continue }
                            switch resolve(section: s, palette: uniform ? 0 : indices[y << 8 | i]) {
                            case .clear:
                                state[i] = .searching
                            case .solid(let color), .water(let color):
                                if ceilingFallback[i] == nil, absoluteY <= start[i] - 5 {
                                    ceilingFallback[i] = Column(y: absoluteY, color: color.shaded(0.6), waterDepth: 0)
                                }
                            case .unresolved:
                                continue
                            }
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
            for i in 0..<256 where state[i] == .ceiling { result[i] = ceilingFallback[i] }
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
        /// The top row has no north neighbor in this region, so its north height is extrapolated from
        /// the row below; leaving it unshaded drew a visible line along every region edge.
        mutating func applyRelief() {
            for z in stride(from: side - 1, through: 0, by: -1) {
                for x in 0..<side {
                    let i = z * side + x
                    let north: Int32
                    if z > 0 {
                        north = heights[i - side]
                    } else {
                        let below = heights[i + side]
                        north = heights[i] == Self.noHeight || below == Self.noHeight ? Self.noHeight : 2 * heights[i] - below
                    }
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
        CGImage.rgba(pixels, width: side, height: side)
    }
}
