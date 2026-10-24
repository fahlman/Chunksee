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
    /// Maximum simultaneous chunk jobs, shared by decoding and coloring.
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
    var darkSpots: DarkSpots?
    /// Only preparation changes with this flag; saved clock values are drawing uniforms.
    var usesSavedLighting = false

    private var currentBiomeColors: MapBiomeColors? {
        biomeColors?.assetSourceKey == gameAssets?.sourceKey ? biomeColors : nil
    }
    var colorSourceKey: String? { currentBiomeColors?.sourceKey ?? gameAssets?.sourceKey }

    var samplesNeighborBiomes: Bool { style != .height && currentBiomeColors?.sampler != nil }

    /// Include unavailable neighbors too, so creating/deleting a file changes the dependency.
    /// Sampled Y also depends on the saved build range even for an explicit cutaway.
    private func biomeDependencyKey(for region: RegionPosition) -> String? {
        guard samplesNeighborBiomes else { return nil }
        let files = Self.neighboringRegions(around: region).sorted { ($0.x, $0.z) < ($1.x, $1.z) }.map { neighbor in
            let stamp = CacheKey.fileStamp(for: dimension.regionURL(.terrain, x: neighbor.x, z: neighbor.z))
            return "\(neighbor.x),\(neighbor.z):" + (stamp.map { "\($0.size),\($0.modified)" } ?? "missing")
        }
        let limits = surfaceContext.dimensionType.map { "\($0.minY)...\($0.maxY)" } ?? "unknown"
        return CacheKey.hash(limits + "\n" + files.joined(separator: "\n"))
    }

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
        if samplesNeighborBiomes, let origin = region.chunkOrigin {
            return try await sampledSurface(in: file, region: region, origin: origin)
        }
        let coordinates = file.chunkCoordinates
        var canvas = Canvas(nightLight: darkSpots == nil ? nil : Array(repeating: DarkSpots.Status.unknown.rawValue, count: Self.side * Self.side))
        if chunkConcurrency <= 1 {
            for (localX, localZ) in coordinates {
                try Task.checkCancellation()
                if let columns = try await coloredColumns(in: file, region: region, localX: localX, localZ: localZ) {
                    canvas.set(columns, chunkX: localX, chunkZ: localZ, style: style, heightScale: heightScale)
                }
            }
        } else {
            try await withThrowingTaskGroup(of: (Int, Int, ColoredChunk)?.self) { group in
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

    private typealias BiomeRows = [Int: [Int: ChunkBiomeSnapshot]]

    private enum BiomeWork: Sendable {
        case decoded(ChunkPosition, ColorInput?)
        case colored(ChunkPosition, ColoredChunk)
    }

    /// A RegionFile owns its entire byte buffer. Read the surrounding ring one file at a time
    /// so compact snapshots, rather than eight complete neighboring files, survive this phase.
    private func neighborBiomes(origin: ChunkPosition, neededBy chunks: Set<ChunkPosition>) async throws -> BiomeRows {
        var positions: [RegionPosition: Set<ChunkPosition>] = [:]
        for chunk in chunks where chunk.x == 0 || chunk.x == 31 || chunk.z == 0 || chunk.z == 31 {
            for z in (chunk.z - 1)...(chunk.z + 1) {
                for x in (chunk.x - 1)...(chunk.x + 1) where !(0..<32).contains(x) || !(0..<32).contains(z) {
                    let absoluteX = origin.x.addingReportingOverflow(x), absoluteZ = origin.z.addingReportingOverflow(z)
                    guard !absoluteX.overflow, !absoluteZ.overflow else { continue }
                    let position = ChunkPosition(x: absoluteX.partialValue, z: absoluteZ.partialValue)
                    positions[position.region, default: []].insert(position)
                }
            }
        }
        var biomes: BiomeRows = [:]
        for region in positions.keys.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
            try Task.checkCancellation()
            guard let file = try? dimension.region(x: region.x, z: region.z) else { continue }
            let sources = positions[region, default: []].filter { file.containsChunk(localX: $0.localX, localZ: $0.localZ) }
                .sorted { ($0.z, $0.x) < ($1.z, $1.x) }
            try await withThrowingTaskGroup(of: (ChunkPosition, ChunkBiomeSnapshot?).self) { group in
                var next = sources.startIndex
                func startNext() {
                    guard next < sources.endIndex else { return }
                    let position = sources[next]; next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let snapshot: ChunkBiomeSnapshot?
                        if let nbt = try? file.chunkNBT(localX: position.localX, localZ: position.localZ,
                                                       skipping: Chunk.keysNotNeededForTerrain),
                           let chunk = try? Chunk(nbt: nbt) { snapshot = chunk.biomeSnapshot }
                        else { snapshot = nil }
                        return (position, snapshot)
                    }
                }
                for _ in 0..<min(max(1, chunkConcurrency), sources.count) { startNext() }
                for try await (position, snapshot) in group {
                    try Task.checkCancellation()
                    if let snapshot { biomes[position.z - origin.z, default: [:]][position.x - origin.x] = snapshot }
                    startNext()
                }
            }
        }
        return biomes
    }

    /// Decode ahead while coloring chunks whose nine neighbor reads have completed. Both jobs
    /// share one worker limit; a four-row window bounds retained compact interior data without a
    /// decode/color barrier after every row. No full Chunk or NBT survives a decode task.
    private func sampledSurface(in file: RegionFile, region: RegionPosition, origin: ChunkPosition) async throws -> Canvas {
        let sources = file.chunkCoordinates.map { ChunkPosition(x: $0.localX, z: $0.localZ) }
            .sorted { ($0.z, $0.x) < ($1.z, $1.x) }
        let present = Set(sources)
        var remaining = [Int](repeating: 0, count: 32)
        for position in present { remaining[position.z] += 1 }
        var firstUnfinished = 0
        var biomes = try await neighborBiomes(origin: origin, neededBy: present)
        var inputs: [ChunkPosition: ColorInput] = [:]
        var decoded: Set<ChunkPosition> = []
        var queued: Set<ChunkPosition> = []
        var ready: [ChunkPosition] = []
        var nextReady = 0, nextSource = 0
        var canvas = Canvas(nightLight: darkSpots == nil ? nil : Array(repeating: DarkSpots.Status.unknown.rawValue, count: Self.side * Self.side))

        func advance() {
            while firstUnfinished < 32, remaining[firstUnfinished] == 0 { firstUnfinished += 1 }
            // Only the immediately preceding row can still supply an unfinished chunk.
            for z in biomes.keys where z < firstUnfinished - 1 { biomes[z] = nil }
        }
        advance()
        try await withThrowingTaskGroup(of: BiomeWork.self) { group in
            var active = 0
            func fillWorkers() {
                while active < max(1, chunkConcurrency) {
                    if nextReady < ready.count {
                        let position = ready[nextReady]; nextReady += 1
                        guard let input = inputs.removeValue(forKey: position) else { continue }
                        // Capture biome buffers only, never other chunks' pending terrain inputs.
                        var neighbors: BiomeRows = [:]
                        for z in (position.z - 1)...(position.z + 1) { neighbors[z] = biomes[z] }
                        let snapshots = neighbors
                        group.addTask {
                            try Task.checkCancellation()
                            let columns = try await coloredColumns(input, region: region, localX: position.x,
                                                                   localZ: position.z, neighbors: snapshots)
                            return .colored(position, columns)
                        }
                    } else {
                        guard firstUnfinished < 32, nextSource < sources.count,
                              sources[nextSource].z <= firstUnfinished + 2 else { break }
                        let position = sources[nextSource]; nextSource += 1
                        group.addTask {
                            try Task.checkCancellation()
                            let scanned = Self.scan(file, localX: position.x, localZ: position.z, context: surfaceContext,
                                                    cutawayY: cutawayY, blockFilter: blockFilter, darkSpots: darkSpots)
                            return .decoded(position, scanned.map { Self.colorInput($0.sections, columns: $0.columns) })
                        }
                    }
                    active += 1
                }
            }
            fillWorkers()
            while let result = try await group.next() {
                try Task.checkCancellation()
                active -= 1
                switch result {
                case .decoded(let position, let input):
                    decoded.insert(position)
                    if let input {
                        biomes[position.z, default: [:]][position.x] = input.biomes
                        inputs[position] = input
                    } else { remaining[position.z] -= 1 }
                    // A completed read can unblock at most the nine chunks that use it.
                    for z in max(0, position.z - 1)...min(31, position.z + 1) {
                        for x in max(0, position.x - 1)...min(31, position.x + 1) {
                            let center = ChunkPosition(x: x, z: z)
                            guard inputs[center] != nil, !queued.contains(center) else { continue }
                            var complete = true
                            for dz in -1...1 {
                                for dx in -1...1 {
                                    let neighbor = ChunkPosition(x: x + dx, z: z + dz)
                                    if present.contains(neighbor), !decoded.contains(neighbor) { complete = false }
                                }
                            }
                            if complete { queued.insert(center); ready.append(center) }
                        }
                    }
                case .colored(let position, let columns):
                    canvas.set(columns, chunkX: position.x, chunkZ: position.z, style: style, heightScale: heightScale)
                    remaining[position.z] -= 1
                }
                advance()
                fillWorkers()
            }
        }
        try await gameAssets?.checkAvailable()
        return canvas
    }

    /// Biome sampling and terrain shadows can use adjacent regions, including diagonal corners.
    static func neighboringRegions(around region: RegionPosition) -> Set<RegionPosition> {
        var regions: Set<RegionPosition> = []
        for dx in -1...1 {
            for dz in -1...1 {
                let x = region.x.addingReportingOverflow(dx), z = region.z.addingReportingOverflow(dz)
                if !x.overflow, !z.overflow { regions.insert(RegionPosition(x: x.partialValue, z: z.partialValue)) }
            }
        }
        return regions
    }

    private func displayPixels(_ surface: Canvas) -> [UInt8] {
        let pixels = style == .height ? surface.pixels : surface.litPixels(heightScale: heightScale)
        return surface.nightLight.map { DarkSpots.applying($0, to: pixels, side: Self.side) } ?? pixels
    }

    @concurrent
    func image(for region: RegionPosition) async throws -> CGImage? {
        try await pixels(for: region).flatMap { Self.makeImage($0, side: Self.side) }
    }

    /// A region's full-resolution image and a half-resolution preview for zoomed-out views.
    struct RenderedTile: Sendable {
        var full: MapTileImage
        var preview: MapTileImage
        var cacheWrite: CacheWrite?
        var detail: MapSurfaceDetail.Surface?
        var heights: [Int32]?

        init(full: MapTileImage, preview: MapTileImage, cacheWrite: CacheWrite? = nil,
             detail: MapSurfaceDetail.Surface? = nil, heights: [Int32]? = nil) {
            self.full = full; self.preview = preview; self.cacheWrite = cacheWrite
            self.detail = detail; self.heights = heights
        }

        init(full: CGImage, preview: CGImage, cacheWrite: CacheWrite? = nil, detail: MapSurfaceDetail.Surface? = nil) {
            self.init(full: MapTileImage(full), preview: MapTileImage(preview), cacheWrite: cacheWrite, detail: detail)
        }
    }

    /// Immutable data for an accepted tile's save. The map owns scheduling/draining it; canceled
    /// render results never start disk work. The actual compression/write stays off the main actor.
    struct CacheWrite: Sendable {
        let cache: TileCache
        let key: TileCache.Key
        let surface: Canvas

        @concurrent
        func store() async {
            cache.store(surface, for: key)
            if !Task.isCancelled { cache.storeDetail(surface, for: key) }
        }
    }

    static let previewSide = side / 2

    /// Runs off the caller's actor: with approachable concurrency a plain nonisolated `async`
    /// method would otherwise run on the main actor when called from the map model.
    @concurrent
    func tile(for region: RegionPosition) async throws -> RenderedTile? {
        if style != .height { try await gameAssets?.checkAvailable() }
        // The key is taken before rendering, so a file changed mid-render is re-rendered next time.
        let key = cacheKey(for: region)
        var surface: Canvas?
        var cacheWrite: CacheWrite?
        var scanned = false
        if let cache, let key, let cached = cache.load(key) {
            surface = cached
        } else {
            surface = try await self.surface(for: region)
            scanned = true
            if let cache, let key, let surface {
                if savesInBackground {
                    cacheWrite = CacheWrite(cache: cache, key: key, surface: surface)
                } else {
                    cache.store(surface, for: key)
                    cache.storeDetail(surface, for: key)
                }
            }
        }
        guard let surface else { return nil }
        var drawing = style == .height ? (pixels: surface.pixels, normals: nil as [UInt8]?)
            : surface.drawingPixels(heightScale: heightScale, includesNormals: usesSavedLighting)
        if let nightLight = surface.nightLight {
            drawing.pixels = DarkSpots.applying(nightLight, to: drawing.pixels, side: Self.side)
        }
        guard let full = Self.makeImage(drawing.pixels),
              let preview = Self.makeImage(Self.halfSize(drawing.pixels), side: Self.previewSide) else { return nil }
        var normals: CGImage?, previewNormals: CGImage?
        if let bytes = drawing.normals {
            normals = CGImage.rgba(bytes, width: Self.side, height: Self.side, colorSpace: CGColorSpace.linearSRGB)
            previewNormals = CGImage.rgba(Self.halfSizeNormals(bytes, colors: drawing.pixels),
                                         width: Self.previewSide, height: Self.previewSide, colorSpace: CGColorSpace.linearSRGB)
            guard normals != nil, previewNormals != nil else { return nil }
        }
        return RenderedTile(full: MapTileImage(full, normals: normals), preview: MapTileImage(preview, normals: previewNormals),
                            cacheWrite: cacheWrite,
                            detail: scanned && gameAssets != nil && style != .height ? surface.detailSurface : nil,
                            heights: style == .height ? nil : surface.heights)
    }

    /// Reuse the existing scan's sidecar only when close-up pixels are requested. A missing
    /// sidecar (including disabled caching) uses the same renderer, never another block parser.
    @concurrent
    func detail(for region: RegionPosition) async throws -> MapSurfaceDetail.Surface? {
        guard gameAssets != nil, style != .height else { return nil }
        try await gameAssets?.checkAvailable()
        let key = cacheKey(for: region)
        if let cache, let key, let detail = cache.loadDetail(key) { return detail }
        guard let surface = try await surface(for: region) else { return nil }
        try Task.checkCancellation()
        if let cache, let key { cache.storeDetail(surface, for: key) }
        return surface.detailSurface
    }

    private func cacheKey(for region: RegionPosition) -> TileCache.Key? {
        guard cache != nil else { return nil }
        return TileCache.key(for: region, regionFile: dimension.regionURL(.terrain, x: region.x, z: region.z),
            context: surfaceContext, cutawayY: cutawayY, style: style, heightScale: heightScale, blockFilter: blockFilter,
            colorSource: style == .height ? nil : colorSourceKey, biomeSource: biomeDependencyKey(for: region), darkSpots: darkSpots)
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

    /// Ignore missing columns when combining normals. A preview pixel containing any water
    /// keeps the water marker, preserving the depth palette along partially covered shores.
    static func halfSizeNormals(_ normals: [UInt8], colors: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: previewSide * previewSide * 4)
        for z in 0..<previewSide {
            for x in 0..<previewSide {
                let a = (2 * z * side + 2 * x) * 4, b = a + side * 4
                var sum = SIMD3<Double>.zero
                var water = false
                for i in [a, a + 4, b, b + 4] where colors[i + 3] != 0 {
                    if normals[i] == 0 && normals[i + 1] == 0 && normals[i + 2] == 0 { water = true }
                    else { sum += SIMD3(Double(normals[i]), Double(normals[i + 1]), Double(normals[i + 2])) / 127.5 - SIMD3(repeating: 1) }
                }
                let i = (z * previewSide + x) * 4
                if !water { encodeNormal(sum, into: &out, at: i) }
                out[i + 3] = 255
            }
        }
        return out
    }

    static func encodeNormal(_ vector: SIMD3<Double>, into pixels: inout [UInt8], at i: Int) {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        let normal = length > 0 ? vector / length : SIMD3(0, 1, 0)
        for c in 0..<3 { pixels[i + c] = UInt8(min(255, max(0, ((normal[c] + 1) * 127.5).rounded()))) }
    }

    /// The 256 top columns of one chunk (index `z * 16 + x`), or `nil` when it can't be decoded.
    /// One damaged chunk shouldn't blank the whole region; it's left transparent instead.
    static func columns(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil, blockFilter: MapBlockFilter = MapBlockFilter()) -> [Column?]? {
        scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY, blockFilter: blockFilter)?.columns
    }

    /// Selected terrain and biome palettes, without retaining a full Chunk or its NBT.
    private struct ColorInput: Sendable {
        let columns: [Column?]
        let biomes: ChunkBiomeSnapshot
        let states: [BlockState]
        let positions: [(surface: Int?, floor: Int?)]
    }

    private static func colorInput(_ sections: ColorSections, columns: [Column?]) -> ColorInput {
        var indices: [PaletteEntry: Int] = [:]
        var states: [BlockState] = []
        func index(for entry: PaletteEntry) -> Int? {
            if let index = indices[entry] { return index }
            guard let state = sections.blockState(at: entry) else { return nil }
            let index = states.count
            states.append(state)
            indices[entry] = index
            return index
        }
        let positions = columns.map { column -> (surface: Int?, floor: Int?) in
            guard let column else { return (nil, nil) }
            return (column.waterDepth == 0 ? index(for: PaletteEntry(section: column.section, palette: column.palette)) : nil,
                    column.waterFloor.flatMap { index(for: $0) })
        }
        return ColorInput(columns: columns, biomes: sections.biomeSnapshot, states: states, positions: positions)
    }

    struct ColoredChunk: Sendable {
        let columns: [Column?]
        var detail: MapSurfaceDetail.Chunk? = nil
    }

    private func coloredColumns(in file: RegionFile, region: RegionPosition, localX: Int, localZ: Int) async throws -> ColoredChunk? {
        guard let scanned = Self.scan(file, localX: localX, localZ: localZ, context: surfaceContext,
                                      cutawayY: cutawayY, blockFilter: blockFilter, darkSpots: darkSpots) else { return nil }
        guard style != .height, gameAssets != nil else { return ColoredChunk(columns: scanned.columns) }
        return try await coloredColumns(Self.colorInput(scanned.sections, columns: scanned.columns),
                                        region: region, localX: localX, localZ: localZ, neighbors: [:])
    }

    /// Color the selected blocks without another decode or traversal. Neighbor keys are local
    /// chunk offsets from this region, including the one-chunk ring at -1 and 32.
    private func coloredColumns(_ scanned: ColorInput, region: RegionPosition, localX: Int, localZ: Int,
                                neighbors: BiomeRows) async throws -> ColoredChunk {
        guard let gameAssets else { return ColoredChunk(columns: scanned.columns) }
        let biomeColors = currentBiomeColors
        let usesBiomeColors = biomeColors != nil
        let states = scanned.states
        var positions = scanned.positions
        var biomes = PreparedBiomes()
        func biome(column: Int, y: Int) -> MapBiomeColors.Biome? {
            guard let point = coordinates(column) else { return nil }
            return biomes.biome(at: BlockPosition(blockX: Int(point.x), blockY: y, blockZ: Int(point.z)))
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
        if usesBiomeColors {
            let materials: [MapBlockMaterial]
            if let cached = gameAssets.cachedMapMaterials(for: states) { materials = cached }
            else { materials = try await gameAssets.mapMaterials(for: states) }
            // Copy the small descriptors once per palette. Reading cached material objects
            // per column makes all workers contend on their shared reference counts.
            var tintRanges: [Range<Int>] = []
            var biomeTints: [MapBlockMaterial.BiomeTint] = []
            for material in materials {
                let start = biomeTints.count
                biomeTints.append(contentsOf: material.biomeTints)
                tintRanges.append(start..<biomeTints.count)
            }
            // Prepare only the tint/floor/water samples this chunk will use. The pixel loop
            // then reads task-local integer indices, never shared row/palette buffers.
            var samples: Set<BlockPosition> = []
            func request(_ column: Int, y: Int) {
                guard let point = coordinates(column) else { return }
                samples.insert(BlockPosition(blockX: Int(point.x), blockY: y, blockZ: Int(point.z)))
            }
            func requestTints(_ palette: Int?, column: Int, y: Int) {
                guard let palette else { return }
                for index in tintRanges[palette] {
                    let height = y.addingReportingOverflow(biomeTints[index].yOffset)
                    if !height.overflow { request(column, y: height.partialValue) }
                }
            }
            for (index, position) in positions.enumerated() {
                guard let column = scanned.columns[index] else { continue }
                requestTints(position.surface, column: index, y: column.y)
                let floor = column.y.subtractingReportingOverflow(column.waterDepth)
                if !floor.overflow { requestTints(position.floor, column: index, y: floor.partialValue) }
                if column.waterDepth > 0 { request(index, y: column.y) }
            }
            if let biomeColors {
                biomes = prepareBiomes(samples, current: scanned.biomes, region: region, neighbors: neighbors, colors: biomeColors)
            }
            struct TintKey: Hashable {
                let palette: Int
                let tints: MapBlockColorRequest.Tints
            }
            var tintedIndices: [TintKey: Int] = [:]
            requests = []
            func tintedIndex(_ palette: Int?, column: Int, y: Int) -> Int? {
                guard let palette else { return nil }
                var tints = MapBlockColorRequest.Tints()
                if let point = coordinates(column) {
                    for index in tintRanges[palette] {
                        let tint = biomeTints[index]
                        let height = y.addingReportingOverflow(tint.yOffset)
                        guard !height.overflow else { continue }
                        if let rgb = biome(column: column, y: height.partialValue)?.color(tint.source, x: point.x, z: point.z) {
                            tints.append(.init(index: tint.index, color: rgb))
                        }
                    }
                }
                let key = TintKey(palette: palette, tints: tints)
                if let index = tintedIndices[key] { return index }
                let index = requests.count
                requests.append(MapBlockColorRequest(state: states[palette], tints: tints))
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
        let columns: [Column?] = zip(scanned.columns, positions).enumerated().map { index, pair in
            let (value, position) = pair
            guard var column = value else { return nil }
            if let index = position.surface, let color = colors[index] {
                column.color = color.shaded(column.colorShade)
            }
            if column.waterDepth > 0, let point = coordinates(index),
               let rgb = biome(column: index, y: column.y)?.color(.water, x: point.x, z: point.z) {
                column.color = MapColor(rgb).shaded(column.colorShade)
            }
            if let index = position.floor, let color = colors[index] {
                column.waterFloorColor = color
            }
            return column
        }
        return ColoredChunk(columns: columns,
                            detail: MapSurfaceDetail.Chunk(columns: columns, requests: requests, indices: positions.map(\.surface)))
    }

    /// Each coloring task owns these buffers. Kit still supplies cell selection and palette
    /// addressing; the app interns the resulting names into its resolved color table.
    private struct PreparedBiomes {
        var indices: [BlockPosition: Int] = [:]
        var colors: [MapBiomeColors.Biome] = []

        func biome(at point: BlockPosition) -> MapBiomeColors.Biome? {
            indices[point].map { colors[$0] }
        }
    }

    private func prepareBiomes(_ points: Set<BlockPosition>, current: ChunkBiomeSnapshot,
                               region: RegionPosition, neighbors: BiomeRows,
                               colors: MapBiomeColors) -> PreparedBiomes {
        guard let currentChunk = points.first?.chunk, let origin = region.chunkOrigin else { return PreparedBiomes() }
        let sampler = colors.sampler
        var perBlockAtHeight: [Int: Bool] = [:]
        var sources: [ChunkPosition: Set<BlockPosition>] = [:]
        var cells: [BlockPosition: BlockPosition] = [:]
        for point in points {
            let perBlock: Bool
            if let cached = perBlockAtHeight[point.y] { perBlock = cached }
            else {
                perBlock = current.hasPerBlockBiomes(atBlockY: point.y) == true
                perBlockAtHeight[point.y] = perBlock
            }
            let cell: BlockPosition?
            if perBlock { cell = point }
            else if let sampler {
                cell = surfaceContext.dimensionType.flatMap { sampler.cellOrigin(at: point, in: $0) }
                    ?? sampler.cellOrigin(at: point)
            } else { cell = nil } // A missing seed cannot establish the game's displaced cell.
            guard let cell else { continue }
            cells[point] = cell
            sources[cell.chunk, default: []].insert(cell)
        }
        var result = PreparedBiomes()
        var namedColors: [String: Int] = [:]
        var cellColors: [BlockPosition: Int] = [:]
        for (chunk, cells) in sources {
            let snapshot: ChunkBiomeSnapshot?
            if chunk == currentChunk { snapshot = current }
            else {
                let x = chunk.x.subtractingReportingOverflow(origin.x), z = chunk.z.subtractingReportingOverflow(origin.z)
                guard !x.overflow, !z.overflow else { continue }
                snapshot = neighbors[z.partialValue]?[x.partialValue]
            }
            guard let snapshot else { continue }
            // Each needed cell is read once, grouped by source chunk. No row lookup, saved
            // palette lookup or biome-name hashing remains in the per-column color path.
            for cell in cells {
                guard let name = snapshot.biome(x: cell.x, y: cell.y, z: cell.z) else { continue }
                let index: Int
                if let existing = namedColors[name] { index = existing }
                else {
                    index = result.colors.count
                    result.colors.append(colors.biome(name))
                    namedColors[name] = index
                }
                cellColors[cell] = index
            }
        }
        for (point, cell) in cells { result.indices[point] = cellColors[cell] }
        return result
    }

    /// The block the map shows in each of a chunk's 256 columns (index `z * 16 + x`), for the hover
    /// readout: the same scan the map is drawn with, naming what it found.
    static func topBlocks(in file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext = .unknown, cutawayY: Int? = nil, blockFilter: MapBlockFilter = MapBlockFilter(), darkSpots: DarkSpots? = nil) -> [TopBlock?]? {
        guard let (sections, columns) = scan(file, localX: localX, localZ: localZ, context: context, cutawayY: cutawayY, blockFilter: blockFilter, darkSpots: darkSpots) else { return nil }
        return columns.map { column in
            column.map { TopBlock(id: sections.blockID(section: $0.section, palette: $0.palette), y: $0.y, waterDepth: $0.waterDepth, nightLight: $0.nightLight) }
        }
    }

    private static func scan(_ file: RegionFile, localX: Int, localZ: Int, context: MapSurfaceContext, cutawayY: Int?, blockFilter: MapBlockFilter, darkSpots: DarkSpots? = nil) -> (sections: ColorSections, columns: [Column?])? {
        // Keep the ordinary read profile unchanged. The optional layer samples light from this
        // same decode and surface walk, without retaining a Chunk or adding another scan.
        let skipping = darkSpots?.rule == nil ? Chunk.keysNotNeededForTerrain : Chunk.keysNotNeededForTerrainAndLight
        guard let nbt = try? file.chunkNBT(localX: localX, localZ: localZ, skipping: skipping),
              let chunk = try? Chunk(nbt: nbt) else { return nil }
        var sections = ColorSections(chunk, filter: blockFilter)
        var columns: [Column?]
        if let cutawayY {
            columns = sections.topColumns(from: .height(cutawayY))
        } else if let ceilingY = context.ceilingY {
            columns = sections.topColumns(from: .height(ceilingY), underCeiling: true)
        } else {
            columns = sections.topColumns(from: .surface(height: context.buildHeight))
        }
        if let darkSpots {
            for index in columns.indices {
                guard let column = columns[index] else { continue }
                columns[index]?.nightLight = darkSpots.status(in: chunk, x: index % 16, surfaceY: column.y, z: index / 16)
            }
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
        var nightLight: DarkSpots.Status?
    }

    /// Water is counted only this deep: deeper water is shaded the same, so the scan stops there.
    static let maximumWaterDepth = 32

    /// A column's top block by name, for the hover readout. Under water, `id` is the water, `y`
    /// its surface and `waterDepth` at most `maximumWaterDepth`.
    struct TopBlock: Equatable, Sendable {
        var id: String
        var y: Int
        var waterDepth: Int
        var nightLight: DarkSpots.Status?
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

        var biomeSnapshot: ChunkBiomeSnapshot { chunk.biomeSnapshot }

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
        var detail = MapSurfaceDetail()

        mutating func set(_ chunk: ColoredChunk, chunkX: Int, chunkZ: Int, style: MapStyle, heightScale: MapHeightScale?) {
            set(chunk.columns, chunkX: chunkX, chunkZ: chunkZ, style: style, heightScale: heightScale)
            if let materials = chunk.detail { detail.insert(materials, at: chunkZ * 32 + chunkX) }
        }
        /// Allocated only while Dark Spots is on; ordinary tiles retain their existing layout.
        var nightLight: [UInt8]?

        var detailSurface: MapSurfaceDetail.Surface {
            .init(detail: detail, heights: heights, nightLight: nightLight)
        }

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
            if nightLight != nil { nightLight?[i] = (column.nightLight ?? .unknown).rawValue }
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
            drawingPixels(heightScale: heightScale, includesNormals: false).pixels
        }

        /// Build drawing inputs in the same surface walk as fixed relief, never another chunk scan.
        func drawingPixels(heightScale: MapHeightScale?, includesNormals: Bool) -> (pixels: [UInt8], normals: [UInt8]?) {
            let lighting = MapRelief(heightScale: heightScale, directionalStrength: includesNormals ? 0.25 : 1)
            var normals = includesNormals ? [UInt8](repeating: 0, count: pixels.count) : nil
            var lit = pixels
            for z in 0..<side {
                for x in 0..<side {
                    let i = z * side + x
                    let height = heights[i]
                    guard height != Self.noHeight else { continue }
                    if includesNormals { normals![i * 4 + 3] = 255 }
                    guard !isWater[i] else { continue }
                    let slope = MapRelief.slope(at: i, heights: heights, side: side)
                    if includesNormals {
                        RegionTileRenderer.encodeNormal(slope.normal, into: &normals!, at: i * 4)
                    }
                    let factor = lighting.factor(height: height, north: slope.north, west: slope.west)
                    guard factor != 1 else { continue }
                    let shaded = MapColor(UInt32(pixels[i * 4]) << 16 | UInt32(pixels[i * 4 + 1]) << 8
                                          | UInt32(pixels[i * 4 + 2])).shaded(factor)
                    lit[i * 4] = shaded.red
                    lit[i * 4 + 1] = shaded.green
                    lit[i * 4 + 2] = shaded.blue
                }
            }
            return (lit, normals)
        }
    }

    static func makeImage(_ pixels: [UInt8], side: Int = side) -> CGImage? {
        CGImage.rgba(pixels, width: side, height: side)
    }
}
