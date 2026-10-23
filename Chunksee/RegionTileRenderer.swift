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
    /// Unlit colours and surface heights saved between launches; `nil` renders every time.
    var cache: TileCache?
    /// Saving compresses the colours, heights and water mask, so by default it happens after the tile is
    /// returned. MapModel owns that low-priority write and its lifetime. Tests save synchronously.
    var savesInBackground = true
    /// Nil keeps the normal view from saved dimension context; a height starts each column there.
    var cutawayY: Int?
    var style = MapStyle.normal
    var heightScale: MapHeightScale?
    var blockFilter = MapBlockFilter()
    var gameAssets: GameAssetLibrary?
    var biomeColors: MapBiomeColors?

    private var currentBiomeColors: MapBiomeColors? {
        biomeColors?.assetSourceKey == gameAssets?.sourceKey ? biomeColors : nil
    }
    var colorSourceKey: String? { currentBiomeColors?.sourceKey ?? gameAssets?.sourceKey }

    /// RGBA pixels (premultiplied, row-major, 512×512), or `nil` when the region file doesn't exist.
    /// Columns in ungenerated chunks stay fully transparent.
    @concurrent
    func pixels(for region: RegionPosition) async throws -> [UInt8]? {
        try await surface(for: region).map(displayPixels)
    }

    @concurrent
    private func surface(for region: RegionPosition) async throws -> Canvas? {
        guard style != .height || heightScale != nil,
              let file = try dimension.region(x: region.x, z: region.z) else { return nil }
        let coordinates = file.chunkCoordinates
        var canvas = Canvas()
        if chunkConcurrency <= 1 {
            for (localX, localZ) in coordinates {
                try Task.checkCancellation()
                if let columns = try await coloredColumns(in: file, region: region, localX: localX, localZ: localZ) {
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
                        let columns = try await coloredColumns(in: file, region: region, localX: localX, localZ: localZ)
                        return columns.map { (localX, localZ, $0) }
                    }
                }
                for _ in 0..<chunkConcurrency { startNext() }
                for try await result in group {
                    if let (localX, localZ, columns) = result { canvas.set(columns, chunkX: localX, chunkZ: localZ, style: style, heightScale: heightScale) }
                    startNext()
                }
            }
        }
        if style != .height { try await gameAssets?.checkAvailable() }
        return canvas
    }

    private func displayPixels(_ surface: Canvas) -> [UInt8] {
        style == .height ? surface.pixels : surface.litPixels(heightScale: heightScale)
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
        let surface: Canvas

        @concurrent
        func store() async { cache.store(surface, for: key) }
    }

    static let previewSide = side / 2

    /// Runs off the caller's actor: with approachable concurrency a plain nonisolated `async`
    /// method would otherwise run on the main actor when called from the map model.
    @concurrent
    func tile(for region: RegionPosition) async throws -> RenderedTile? {
        if style != .height { try await gameAssets?.checkAvailable() }
        // The key is taken before rendering, so a file changed mid-render is re-rendered next time.
        let regionFile = dimension.regionURL(.terrain, x: region.x, z: region.z)
        let key = cache == nil ? nil : TileCache.key(for: region, regionFile: regionFile, context: surfaceContext, cutawayY: cutawayY, style: style, heightScale: heightScale, blockFilter: blockFilter, colorSource: style == .height ? nil : colorSourceKey)
        var surface: Canvas?
        var cacheWrite: CacheWrite?
        if let cache, let key, let cached = cache.load(key) {
            surface = cached
        } else {
            surface = try await self.surface(for: region)
            if let cache, let key, let surface {
                if savesInBackground {
                    cacheWrite = CacheWrite(cache: cache, key: key, surface: surface)
                } else {
                    cache.store(surface, for: key)
                }
            }
        }
        guard let surface else { return nil }
        let pixels = displayPixels(surface)
        guard let full = Self.makeImage(pixels, side: Self.side),
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
    static func columns(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil, blockFilter: MapBlockFilter = MapBlockFilter()) -> [Column?]? {
        scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY, blockFilter: blockFilter)?.columns
    }

    /// Color the already selected blocks; do not decode or traverse the chunk a second time.
    private func coloredColumns(in file: RegionFile, region: RegionPosition, localX: Int, localZ: Int) async throws -> [Column?]? {
        guard let scanned = Self.scan(file, localX: localX, localZ: localZ, context: surfaceContext,
                                      cutawayY: cutawayY, blockFilter: blockFilter) else { return nil }
        guard style != .height, let gameAssets else { return scanned.columns }
        let biomeColors = currentBiomeColors
        var indices: [PaletteEntry: Int] = [:]
        var states: [BlockState] = []
        func index(for entry: PaletteEntry) -> Int? {
            if let index = indices[entry] { return index }
            guard let state = scanned.sections.blockState(at: entry) else { return nil }
            let index = states.count
            states.append(state)
            indices[entry] = index
            return index
        }
        var positions = scanned.columns.map { column -> (surface: Int?, floor: Int?) in
            guard let column else { return (nil, nil) }
            let surface = column.waterDepth == 0
                ? index(for: PaletteEntry(section: column.section, palette: column.palette)) : nil
            return (surface, column.waterFloor.flatMap { index(for: $0) })
        }
        let origin = region.blockOrigin
        func coordinates(_ column: Int) -> (x: Int32, z: Int32)? {
            guard let origin else { return nil }
            let x = origin.x.addingReportingOverflow(localX * 16 + column % 16)
            let z = origin.z.addingReportingOverflow(localZ * 16 + column / 16)
            guard !x.overflow, !z.overflow,
                  let x = Int32(exactly: x.partialValue), let z = Int32(exactly: z.partialValue) else { return nil }
            return (x, z)
        }
        var requests = states.map { MapBlockColorRequest(state: $0) }
        if let biomeColors {
            let materials: [MapBlockMaterial]
            if let cached = gameAssets.cachedMapMaterials(for: states) { materials = cached }
            else { materials = try await gameAssets.mapMaterials(for: states) }
            struct TintKey: Hashable {
                let palette: Int
                let tints: [MapBlockColorRequest.Tint]
            }
            var tintedIndices: [TintKey: Int] = [:]
            requests = []
            func tintedIndex(_ palette: Int?, column: Int, y: Int) -> Int? {
                guard let palette else { return nil }
                let material = materials[palette]
                var tints: [MapBlockColorRequest.Tint] = []
                if let point = coordinates(column) {
                    for tint in material.biomeTints {
                        let height = y.addingReportingOverflow(tint.yOffset)
                        guard !height.overflow else { continue }
                        let id = scanned.sections.biome(x: column % 16, y: height.partialValue, z: column / 16)
                        if let rgb = biomeColors.color(tint.source, biome: id, x: point.x, z: point.z) {
                            tints.append(.init(index: tint.index, color: rgb))
                        }
                    }
                }
                let key = TintKey(palette: palette, tints: tints)
                if let index = tintedIndices[key] { return index }
                let index = requests.count
                requests.append(MapBlockColorRequest(state: material.state, tints: tints))
                tintedIndices[key] = index
                return index
            }
            positions = positions.enumerated().map { index, position in
                guard let column = scanned.columns[index] else { return (nil, nil) }
                let floorY = column.y.subtractingReportingOverflow(column.waterDepth)
                return (tintedIndex(position.surface, column: index, y: column.y),
                        floorY.overflow ? nil : tintedIndex(position.floor, column: index, y: floorY.partialValue))
            }
        }
        let colors: [MapColor?]
        if let cached = gameAssets.cachedMapColors(requests: requests) { colors = cached }
        else { colors = try await gameAssets.mapColors(requests: requests) }
        return zip(scanned.columns, positions).enumerated().map { index, pair in
            let (value, position) = pair
            guard var column = value else { return nil }
            if let index = position.surface, let color = colors[index] {
                column.color = color.shaded(column.colorShade)
            }
            if column.waterDepth > 0, let biomeColors, let point = coordinates(index),
               let rgb = biomeColors.color(.water,
                   biome: scanned.sections.biome(x: index % 16, y: column.y, z: index / 16), x: point.x, z: point.z) {
                column.color = MapColor(rgb).shaded(column.colorShade)
            }
            if let index = position.floor, let color = colors[index] {
                column.waterFloorColor = color
            }
            return column
        }
    }

    /// The block the map shows in each of a chunk's 256 columns (index `z * 16 + x`), for the hover
    /// readout: the same scan the map is drawn with, naming what it found.
    static func topBlocks(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil, blockFilter: MapBlockFilter = MapBlockFilter()) -> [TopBlock?]? {
        guard let (sections, columns) = scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY, blockFilter: blockFilter) else { return nil }
        return columns.map { column in
            column.map { TopBlock(id: sections.blockID(section: $0.section, palette: $0.palette), y: $0.y, waterDepth: $0.waterDepth) }
        }
    }

    private static func scan(_ file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext, cutawayY: Int?, blockFilter: MapBlockFilter) -> (sections: ColorSections, columns: [Column?])? {
        // The map needs only blocks and heightmaps; skipping ticks, light and the like is faster.
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ, skipping: Chunk.keysNotNeededForTerrain),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        var sections = ColorSections(chunk, filter: blockFilter)
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

    struct PaletteEntry: Hashable, Sendable {
        var section: Int
        var palette: Int
    }

    /// The highest block the map should show in a column, and how deep the water above it is.
    struct Column: Equatable {
        var y: Int
        var color: MapColor
        var waterDepth: Int
        var emphasis = MapBlockFilter.Emphasis.ordinary
        /// Where the block is in its chunk's section palettes, so it can be named on demand without
        /// copying a block ID for every column the map draws.
        var section = 0
        var palette = 0
        /// The first visible block directly below contiguous water; absent across gaps or at the depth cap.
        var waterFloorColor: MapColor?
        var waterFloor: PaletteEntry?
        var colorShade = 1.0
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
        struct Paint: Equatable {
            var color: MapColor
            var emphasis: MapBlockFilter.Emphasis
        }

        enum Entry: Equatable {
            case unresolved
            case clear
            case solid(Paint)
            case water(Paint)
        }

        private let chunk: Chunk
        private let hiddenIDs: Set<String>
        private let filter: MapBlockFilter
        private var entries: [[Entry]]
        private let highestSection: Int?

        func blockID(section: Int, palette: Int) -> String {
            blockState(at: PaletteEntry(section: section, palette: palette))?.id ?? ""
        }

        func biome(x: Int, y: Int, z: Int) -> String? { chunk.biome(x: x, y: y, z: z) }

        func blockState(at entry: PaletteEntry) -> BlockState? {
            guard chunk.sections.indices.contains(entry.section),
                  let states = chunk.sections[entry.section].blockStates,
                  states.palette.indices.contains(entry.palette) else { return nil }
            return states.palette[entry.palette]
        }

        init(_ chunk: Chunk, filter: MapBlockFilter = MapBlockFilter()) {
            self.chunk = chunk
            self.filter = filter
            hiddenIDs = filter.effectiveHiddenIDs
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
                let color = hiddenIDs.contains(id) ? nil : BlockColors.color(for: id)
                if let color {
                    let paint = Paint(color: color, emphasis: filter.emphasis(for: id))
                    entries[s][p] = BlockColors.isWater(id) ? .water(paint) : .solid(paint)
                } else {
                    entries[s][p] = .clear
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
                        case .solid(let paint), .water(let paint):
                            // Preserve the dark fallback below the five-block roof band when a
                            // column never reaches open space. A span may cross that band's edge.
                            if states[i].column == nil, let ceiling = states[i].ceilingStart {
                                let belowBand = ceiling.subtractingReportingOverflow(5)
                                let y = min(run.y.upperBound, belowBand.partialValue)
                                if !belowBand.overflow, y >= run.y.lowerBound {
                                    states[i].column = Column(y: y, color: paint.color.shaded(0.6), waterDepth: 0, emphasis: paint.emphasis,
                                                              section: run.sectionIndex, palette: palette, colorShade: 0.6)
                                }
                            }
                        case .unresolved:
                            break
                        }
                        return true
                    case .searching:
                        switch entry {
                        case .solid(let paint):
                            states[i].column = Column(y: run.y.upperBound, color: paint.color, waterDepth: 0, emphasis: paint.emphasis,
                                                      section: run.sectionIndex, palette: palette)
                            states[i].phase = .done
                            return false
                        case .water(let paint):
                            let depth = min(run.y.count, RegionTileRenderer.maximumWaterDepth)
                            states[i].column = Column(y: run.y.upperBound, color: paint.color, waterDepth: depth, emphasis: paint.emphasis,
                                                      section: run.sectionIndex, palette: palette)
                            states[i].waterBottom = run.y.lowerBound
                            states[i].phase = depth == RegionTileRenderer.maximumWaterDepth ? .done : .water
                            return states[i].phase == .water
                        default:
                            return true
                        }
                    case .water:
                        guard case .water = entry, var column = states[i].column else {
                            if case .solid(let paint) = entry {
                                states[i].column?.waterFloorColor = paint.color
                                states[i].column?.waterFloor = PaletteEntry(section: run.sectionIndex, palette: palette)
                            }
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
    struct Canvas: Sendable {
        static let noHeight = Int32.min

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var heights = [Int32](repeating: noHeight, count: side * side)
        var isWater = [Bool](repeating: false, count: side * side)

        mutating func set(x: Int, z: Int, column: Column) {
            set(x: x, z: z, column: column, color: baseColor(for: column))
        }

        private mutating func set(x: Int, z: Int, column: Column, color: MapColor) {
            guard let height = Int32(exactly: column.y), height != Self.noHeight else { return }
            let color = column.emphasis.applying(to: color)
            let i = z * side + x
            pixels[i * 4] = color.red
            pixels[i * 4 + 1] = color.green
            pixels[i * 4 + 2] = color.blue
            pixels[i * 4 + 3] = 255
            heights[i] = height
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

        /// Lighting is applied to a copy, so a cached surface can be lit again without reading chunks.
        /// Top/left differences extrapolate from the next row/column to avoid an unshaded region edge.
        func litPixels(heightScale: MapHeightScale?) -> [UInt8] {
            let lighting = MapRelief(heightScale: heightScale)
            var lit = pixels
            for z in 0..<side {
                for x in 0..<side {
                    let i = z * side + x
                    let height = heights[i]
                    guard height != Self.noHeight, !isWater[i] else { continue }
                    let north = heights[z > 0 ? i - side : i + side]
                    let west = heights[x > 0 ? i - 1 : i + 1]
                    let northDifference = north == Self.noHeight ? 0
                        : (Int64(height) - Int64(north)) * (z > 0 ? 1 : -1)
                    let westDifference = west == Self.noHeight ? 0
                        : (Int64(height) - Int64(west)) * (x > 0 ? 1 : -1)
                    let factor = lighting.factor(height: height, north: northDifference, west: westDifference)
                    guard factor != 1 else { continue }
                    let shaded = MapColor(UInt32(pixels[i * 4]) << 16 | UInt32(pixels[i * 4 + 1]) << 8
                                          | UInt32(pixels[i * 4 + 2])).shaded(factor)
                    lit[i * 4] = shaded.red
                    lit[i * 4 + 1] = shaded.green
                    lit[i * 4 + 2] = shaded.blue
                }
            }
            return lit
        }
    }

    static func makeImage(_ pixels: [UInt8], side: Int = side) -> CGImage? {
        CGImage.rgba(pixels, width: side, height: side)
    }
}
