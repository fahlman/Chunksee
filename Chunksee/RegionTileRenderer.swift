import CoreGraphics
import Foundation
import ChunkseeKit

/// Renders one region (512×512 blocks) of a dimension as a top-down image, one pixel per block.
///
/// Rendering reads and decodes up to 1,024 chunks, so it runs off the main actor and checks for
/// cancellation between chunks. With `chunkConcurrency` above 1, chunks decode in parallel.
nonisolated struct RegionTileRenderer: Sendable {
    /// The one-pixel-per-block canvas used by terrain, overlays and viewport geometry.
    static let side = 512

    let dimension: ChunkseeKit.Dimension
    /// Saved type/generation context, shared with hover reads and the region scanner.
    var surfaceContext: MapSurfaceContext = .unknown
    /// How many chunks of one region decode at the same time.
    var chunkConcurrency = 1
    /// Rendered pixels saved between launches; `nil` renders every time.
    var cache: TileCache?
    /// Saving compresses and writes about 1 MB, so by default it happens after the tile is
    /// returned. MapModel owns that low-priority write and its lifetime. Tests save synchronously.
    var savesInBackground = true
    /// Nil keeps the normal view from saved dimension context; a height starts each column there.
    var cutawayY: Int?
    var style = MapStyle.normal
    var heightScale: MapHeightScale?

    /// RGBA pixels (premultiplied, row-major, 512×512), or `nil` when the region file doesn't exist.
    /// Columns in ungenerated chunks stay fully transparent.
    @concurrent
    func pixels(for region: RegionPosition) async throws -> [UInt8]? {
        guard style != .height || heightScale != nil,
              let file = try dimension.region(x: region.x, z: region.z) else { return nil }
        let coordinates = file.chunkCoordinates
        var canvas = Canvas()
        if chunkConcurrency <= 1 {
            for (localX, localZ) in coordinates {
                try Task.checkCancellation()
                if let columns = Self.columns(in: file, localX: localX, localZ: localZ, context: surfaceContext, cutawayY: cutawayY) {
                    canvas.set(columns, chunkX: localX, chunkZ: localZ, style: style, heightScale: heightScale)
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
                        return Self.columns(in: file, localX: localX, localZ: localZ, context: surfaceContext, cutawayY: cutawayY).map { (localX, localZ, $0) }
                    }
                }
                for _ in 0..<chunkConcurrency { startNext() }
                for try await result in group {
                    if let (localX, localZ, columns) = result { canvas.set(columns, chunkX: localX, chunkZ: localZ, style: style, heightScale: heightScale) }
                    startNext()
                }
            }
        }
        if style != .height { canvas.applyRelief() }
        return canvas.pixels
    }

    @concurrent
    func image(for region: RegionPosition) async throws -> CGImage? {
        try await pixels(for: region).flatMap { Self.makeImage($0, side: Self.side) }
    }

    /// A region's full-resolution image and a half-resolution preview for zoomed-out views.
    struct RenderedTile: @unchecked Sendable {  // CGImage is immutable.
        var full: CGImage
        var preview: CGImage
        var cacheWrite: CacheWrite? = nil
    }

    /// Immutable data for an accepted tile's save. The map owns scheduling/draining it; canceled
    /// render results never start disk work. The actual compression/write stays off the main actor.
    struct CacheWrite: Sendable {
        let cache: TileCache
        let key: TileCache.Key
        let pixels: [UInt8]

        @concurrent
        func store() async { cache.store(pixels, for: key) }
    }

    static let previewSide = side / 2

    /// Runs off the caller's actor: with approachable concurrency a plain nonisolated `async`
    /// method would otherwise run on the main actor when called from the map model.
    @concurrent
    func tile(for region: RegionPosition) async throws -> RenderedTile? {
        // The key is taken before rendering, so a file changed mid-render is re-rendered next time.
        let regionFile = dimension.regionURL(.terrain, x: region.x, z: region.z)
        let key = cache == nil ? nil : TileCache.key(for: region, regionFile: regionFile, context: surfaceContext, cutawayY: cutawayY, style: style, heightScale: heightScale)
        var pixels: [UInt8]?
        var cacheWrite: CacheWrite?
        if let cache, let key, let cached = cache.load(key) {
            pixels = cached
        } else {
            pixels = try await self.pixels(for: region)
            if let cache, let key, let pixels {
                if savesInBackground {
                    cacheWrite = CacheWrite(cache: cache, key: key, pixels: pixels)
                } else {
                    cache.store(pixels, for: key)
                }
            }
        }
        guard let pixels,
              let full = Self.makeImage(pixels, side: Self.side),
              let preview = Self.makeImage(Self.halfSize(pixels), side: Self.previewSide) else { return nil }
        return RenderedTile(full: full, preview: preview, cacheWrite: cacheWrite)
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
    static func columns(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil) -> [Column?]? {
        scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY)?.columns
    }

    /// The block the map shows in each of a chunk's 256 columns (index `z * 16 + x`), for the hover
    /// readout: the same scan the map is drawn with, naming what it found.
    static func topBlocks(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil) -> [TopBlock?]? {
        guard let (sections, columns) = scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY) else { return nil }
        return columns.map { column in
            column.map { TopBlock(id: sections.blockID(section: $0.section, palette: $0.palette), y: $0.y, waterDepth: $0.waterDepth) }
        }
    }

    private static func scan(_ file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext, cutawayY: Int?) -> (sections: ColorSections, columns: [Column?])? {
        // The map needs only blocks and heightmaps; skipping ticks, light and the like is faster.
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ, skipping: Chunk.keysNotNeededForTerrain),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        var sections = ColorSections(chunk)
        let columns: [Column?]
        if let cutawayY {
            columns = sections.topColumns(from: .height(cutawayY))
        } else if let ceilingY = context.ceilingY {
            columns = sections.topColumns(from: .height(ceilingY), underCeiling: true)
        } else {
            columns = sections.topColumns(from: .surface(height: context.buildHeight))
        }
        return (sections, columns)
    }

    /// The highest block the map should show in a column, and how deep the water above it is.
    struct Column: Equatable {
        var y: Int
        var color: MapColor
        var waterDepth: Int
        /// Where the block is in its chunk's section palettes, so it can be named on demand without
        /// copying a block ID for every column the map draws.
        var section = 0
        var palette = 0
        /// The first visible block directly below contiguous water; absent across gaps or at the depth cap.
        var waterFloorColor: MapColor?
    }

    /// Water is counted only this deep: deeper water is shaded the same, so the scan stops there.
    static let maximumWaterDepth = 32

    /// A column's top block by name, for the hover readout. Under water, `id` is the water, `y`
    /// its surface and `waterDepth` at most `maximumWaterDepth`.
    struct TopBlock: Equatable, Sendable {
        var id: String
        var y: Int
        var waterDepth: Int
    }

    /// Presentation resolved once per reached palette entry. Kit owns the saved-block traversal;
    /// colors, contiguous-water shading and the view below a roof are app choices.
    struct ColorSections {
        enum Entry: Equatable {
            case unresolved
            case clear
            case solid(MapColor)
            case water(MapColor)
        }

        private let chunk: Chunk
        private var entries: [[Entry]]
        private let highestSection: Int?

        func blockID(section: Int, palette: Int) -> String {
            guard chunk.sections.indices.contains(section),
                  let states = chunk.sections[section].blockStates,
                  states.palette.indices.contains(palette) else { return "" }
            return states.palette[palette].id
        }

        init(_ chunk: Chunk) {
            self.chunk = chunk
            entries = chunk.sections.map { section in
                Array(repeating: .unresolved, count: section.blockStates?.palette.count ?? 0)
            }
            highestSection = entries.lastIndex { !$0.isEmpty }
        }

        @inline(__always)
        private mutating func resolve(section s: Int, palette: Int?) -> Entry {
            guard let p = palette, entries[s].indices.contains(p) else { return .clear }
            if entries[s][p] == .unresolved {
                let id = blockID(section: s, palette: p)
                entries[s][p] = switch BlockColors.color(for: id) {
                case nil: .clear
                case let color? where BlockColors.isWater(id): .water(color)
                case let color?: .solid(color)
                }
            }
            return entries[s][p]
        }

        /// Draw each column during Kit's shared traversal, without computing its surface and
        /// unpacking the same sections a second time. Uniform spans also avoid per-block work.
        mutating func topColumns(from start: Chunk.ColumnStart = .surface(), underCeiling: Bool = false) -> [Column?] {
            enum Phase { case ceiling, searching, water, done }
            struct ColumnState {
                var phase: Phase
                var column: Column?
                var ceilingStart: Int?
                var waterBottom = 0
            }
            var states = [ColumnState](repeating: ColumnState(phase: underCeiling ? .ceiling : .searching), count: 256)
            let chunk = self.chunk
            // The synchronous, nonescaping visitor stays inside this chunk's buffer lifetime.
            // Buffer writes avoid checking captured arrays for copy-on-write on every block.
            states.withUnsafeMutableBufferPointer { states in
                chunk.forEachColumnRun(from: start) { run in
                    let i = run.column
                    if states[i].phase == .water {
                        let expected = states[i].waterBottom.subtractingReportingOverflow(1)
                        if expected.overflow || run.y.upperBound != expected.partialValue {
                            states[i].phase = .done
                            return false // Missing sections cannot add to contiguous water depth.
                        }
                    }
                    let entry = resolve(section: run.sectionIndex, palette: run.paletteIndex)
                    // Only a resolved solid/water entry can create a Column; an invalid reference is clear.
                    let palette = run.paletteIndex ?? 0
                    switch states[i].phase {
                    case .done:
                        return false
                    case .ceiling:
                        if states[i].ceilingStart == nil {
                            // Kit clipped the top section's run. If higher sections were skipped, the
                            // requested Y is already below the chunk's top and remains the roof start.
                            if run.sectionIndex == highestSection { states[i].ceilingStart = run.y.upperBound }
                            else if case .height(let y) = start { states[i].ceilingStart = y }
                        }
                        switch entry {
                        case .clear:
                            states[i].phase = .searching
                            states[i].column = nil
                        case .solid(let color), .water(let color):
                            // Preserve the dark fallback below the five-block roof band when a
                            // column never reaches open space. A span may cross that band's edge.
                            if states[i].column == nil, let ceiling = states[i].ceilingStart {
                                let belowBand = ceiling.subtractingReportingOverflow(5)
                                let y = min(run.y.upperBound, belowBand.partialValue)
                                if !belowBand.overflow, y >= run.y.lowerBound {
                                    states[i].column = Column(y: y, color: color.shaded(0.6), waterDepth: 0,
                                                              section: run.sectionIndex, palette: palette)
                                }
                            }
                        case .unresolved:
                            break
                        }
                        return true
                    case .searching:
                        switch entry {
                        case .solid(let color):
                            states[i].column = Column(y: run.y.upperBound, color: color, waterDepth: 0,
                                                      section: run.sectionIndex, palette: palette)
                            states[i].phase = .done
                            return false
                        case .water(let color):
                            let depth = min(run.y.count, RegionTileRenderer.maximumWaterDepth)
                            states[i].column = Column(y: run.y.upperBound, color: color, waterDepth: depth,
                                                      section: run.sectionIndex, palette: palette)
                            states[i].waterBottom = run.y.lowerBound
                            states[i].phase = depth == RegionTileRenderer.maximumWaterDepth ? .done : .water
                            return states[i].phase == .water
                        default:
                            return true
                        }
                    case .water:
                        guard case .water = entry, var column = states[i].column else {
                            if case .solid(let color) = entry { states[i].column?.waterFloorColor = color }
                            states[i].phase = .done
                            return false
                        }
                        column.waterDepth += min(run.y.count, RegionTileRenderer.maximumWaterDepth - column.waterDepth)
                        states[i].column = column
                        states[i].waterBottom = run.y.lowerBound
                        states[i].phase = column.waterDepth == RegionTileRenderer.maximumWaterDepth ? .done : .water
                        return states[i].phase == .water
                    }
                }
            }
            return states.map { $0.column }
        }
    }

    static func baseColor(for column: Column) -> MapColor {
        guard column.waterDepth > 0 else { return column.color }
        let water = column.color.shaded(1.15 - min(Double(column.waterDepth), 24) / 40)
        guard let floor = column.waterFloorColor, column.waterDepth < 16 else { return water }
        // Retain a blue cast at the shore, fading the visible floor out over sixteen blocks.
        return floor.blended(with: water, amount: 0.2 + Double(column.waterDepth) / 20)
    }

    /// Pixels plus the surface height of each column, kept so relief shading can compare
    /// neighbors across chunk edges after every chunk is drawn.
    struct Canvas {
        static let noHeight = Int32.min

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var heights = [Int32](repeating: noHeight, count: side * side)
        var isWater = [Bool](repeating: false, count: side * side)

        mutating func set(x: Int, z: Int, column: Column) {
            set(x: x, z: z, column: column, color: baseColor(for: column))
        }

        private mutating func set(x: Int, z: Int, column: Column, color: MapColor) {
            let i = z * side + x
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

        mutating func set(_ columns: [Column?], chunkX: Int, chunkZ: Int, style: MapStyle, heightScale: MapHeightScale?) {
            // Normal keeps its existing loop; alternate colours use the same decoded columns.
            guard style != .normal else {
                set(columns, chunkX: chunkX, chunkZ: chunkZ)
                return
            }
            for (i, column) in columns.enumerated() {
                guard let column else { continue }
                let color: MapColor
                if style == .height {
                    guard let heightScale else { continue }
                    color = MapStylePalette.heightColor(y: column.y, scale: heightScale)
                } else if column.waterDepth > 0 {
                    color = MapStylePalette.waterColor(depth: column.waterDepth)
                } else {
                    color = column.color
                }
                set(x: chunkX * 16 + i % 16, z: chunkZ * 16 + i / 16, column: column, color: color)
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
