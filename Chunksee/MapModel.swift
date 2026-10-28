import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// Tiles and viewport for one dimension's top-down map.
@Observable
final class MapModel {
    let dimension: ChunkseeKit.Dimension
    var viewport: MapViewport {
        didSet {
            if showsDarkSpots, Self.chunk(at: viewport.center) != Self.chunk(at: oldValue.center) {
                updateTopBlockReads()
            }
        }
    }
    private(set) var depth = MapDepth()
    private(set) var style = MapStyle.normal
    private(set) var blendsBiomeColors = false
    private(set) var lightingMode = MapLightingMode.savedTime
    private(set) var savedLighting: MapLighting?
    var lighting: MapLighting? { style != .height && lightingMode == .savedTime ? savedLighting : nil }
    private(set) var castsShadows = true
    var shadowLight: MapShadow.Light? {
        guard castsShadows, style != .height else { return nil }
        if let lighting { return MapShadow.Light.saved(lighting.direction) }
        return .daylight
    }
    private(set) var shadowImages: [RegionPosition: CGImage] = [:]
    @ObservationIgnored private var shadowHeights: [RegionPosition: [Int32]] = [:]
    private var shadowSources: Set<RegionPosition> = []
    private var shadowJob: Task<Void, Never>?
    private var shadowRevision = 0
    private var shadowsNeedUpdate = false
    private(set) var blockFilter = MapBlockFilter()
    private(set) var showsDarkSpots = false
    private(set) var nightLighting: MonsterSpawnLight?
    var darkSpots: DarkSpots? { showsDarkSpots ? DarkSpots(rule: nightLighting) : nil }
    private(set) var heightScale: MapHeightScale?

    /// Full-resolution tiles (512×512), kept for the regions near the view.
    private(set) var tiles: [RegionPosition: MapTileImage] = [:]
    /// Half-resolution previews (256×256, a quarter of the memory), kept for many more regions so
    /// zoomed-out views never thrash and zooming in shows something at once.
    private(set) var previews: [RegionPosition: MapTileImage] = [:]
    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionPosition>
    private(set) var isLoading = false
    /// Only visible close-up chunks are drawn at texture resolution; ordinary tiles stay underneath.
    private(set) var detailImages: [ChunkPosition: MapTileImage] = [:]
    @ObservationIgnored private var detailSurfaces: [RegionPosition: MapSurfaceDetail.Surface] = [:]
    @ObservationIgnored private var detailAttempted: Set<ChunkPosition> = []
    @ObservationIgnored private var detailQueue: [ChunkPosition] = []
    @ObservationIgnored private var detailJob: (chunk: ChunkPosition, id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var detailRegionsWanted: Set<RegionPosition> = []
    @ObservationIgnored private var detailLoadsAttempted: Set<RegionPosition> = []
    @ObservationIgnored private var detailLoadJob: (region: RegionPosition, id: UUID, task: Task<Void, Never>)?
    typealias DetailRenderer = @Sendable (ChunkPosition, MapSurfaceDetail.Surface, GameArtworkLibrary, MapHeightScale?, Bool) async throws -> MapTileImage?
    typealias DetailReader = @Sendable (RegionTileRenderer, RegionPosition) async throws -> MapSurfaceDetail.Surface?
    @ObservationIgnored private let renderDetail: DetailRenderer
    @ObservationIgnored private let readDetail: DetailReader

    private var failed: Set<RegionPosition> = []
    private var renderer: RegionTileRenderer
    private var gameData: GameDataLibrary?
    private var gameArtwork: GameArtworkLibrary?
    private var biomeColors: MapBiomeColors?
    /// A value snapshot also used by image exports, preserving this map's view and cache rules.
    var currentRenderer: RegionTileRenderer {
        var current = renderer
        current.cutawayY = depth.cutawayY
        current.style = style
        current.blendsBiomeColors = blendsBiomeColors
        current.usesSavedLighting = lighting != nil
        current.blockFilter = blockFilter
        current.darkSpots = darkSpots
        current.gameData = style == .height ? nil : gameData
        current.gameArtwork = style == .height ? nil : gameArtwork
        current.biomeColors = style == .height ? nil : biomeColors
        return current
    }
    private let work: BackgroundWork
    private let renderWork, cacheWork, readoutWork, coordinateWork, detailWork, shadowWork: BackgroundWork.Scope
    @ObservationIgnored private let writeCache: @Sendable (RegionTileRenderer.CacheWrite) async -> Void
    var unfinishedCacheWrites: Int { cacheWork.unfinishedCount }
    @ObservationIgnored let renderTile: @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
    /// Full color/normal images plus retained materials share the existing roughly 200 MB
    /// budget. Previews keep their separate 200 MB budget. Visible tiles are never evicted,
    /// so a very large window can exceed these rather than show blanks.
    private let maxTiles: Int
    private let maxPreviews: Int
    private let regionConcurrency: Int

    /// Measured on a 14-core M4 Pro (fahlman/Chunksee#3): rendering regions and their chunks one
    /// per core filled every tested view fastest or tied-fastest, and the cooperative thread pool
    /// keeps the total thread count at the core count however many tasks are queued.
    static let defaultConcurrency = ProcessInfo.processInfo.activeProcessorCount

    init(work: BackgroundWork, dimension: ChunkseeKit.Dimension, center: CGPoint,
         regionConcurrency: Int = MapModel.defaultConcurrency, chunkConcurrency: Int = MapModel.defaultConcurrency,
         maxTiles: Int = 200, maxPreviews: Int = 800, cacheDirectory: URL? = nil,
         surfaceContext: MapSurfaceContext = .unknown, heightScale: MapHeightScale? = nil,
         writeCache: @escaping @Sendable (RegionTileRenderer.CacheWrite) async -> Void = { await $0.store() },
         renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
            = { try await $0.tile(for: $1) },
         renderDetail: @escaping DetailRenderer = { try await MapDetailRenderer.render($0, surface: $1, assets: $2, heightScale: $3, usesSavedLighting: $4) },
         readDetail: @escaping DetailReader = { try await $0.detail(for: $1) },
         readTopBlocks: @escaping TopBlockReader
            = { await MapModel.readTopBlocks(of: $0, using: $1, cached: $2) }) {
        self.work = work
        renderWork = work.makeScope()
        cacheWork = work.makeScope()
        readoutWork = work.makeScope()
        coordinateWork = work.makeScope()
        detailWork = work.makeScope()
        self.renderDetail = renderDetail
        self.readDetail = readDetail
        shadowWork = work.makeScope()
        self.dimension = dimension
        self.heightScale = heightScale
        self.readTopBlocksFor = readTopBlocks
        self.renderTile = renderTile
        self.writeCache = writeCache
        self.maxTiles = maxTiles
        self.maxPreviews = maxPreviews
        self.regionConcurrency = max(1, regionConcurrency)
        self.renderer = RegionTileRenderer(dimension: dimension, surfaceContext: surfaceContext,
                                           chunkConcurrency: max(1, chunkConcurrency),
                                           cache: cacheDirectory.map(TileCache.init(directory:)), heightScale: heightScale)
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionPosition(x: $0.x, z: $0.z) })
    }

    /// Whether the view shows regions large enough on screen to need full-resolution tiles:
    /// more than a preview's 256 pixels, at the display's pixel density.
    func needsFullResolution(displayScale: CGFloat) -> Bool {
        viewport.scale * CGFloat(RegionTileRenderer.side) * displayScale > CGFloat(RegionTileRenderer.previewSide)
    }

    /// The image to draw for a region: the sharpest one cached that the view needs.
    func image(for region: RegionPosition, fullResolution: Bool) -> MapTileImage? {
        fullResolution ? (tiles[region] ?? previews[region]) : (previews[region] ?? tiles[region])
    }

    /// Starts rendering the visible regions that lack the resolution the view needs, nearest to the
    /// center first. A new request replaces the previous one, so panning away cancels work that's
    /// no longer visible.
    func requestTiles(visibleIn size: CGSize, displayScale: CGFloat = 2) {
        guard !isClosed, size.width > 0, size.height > 0 else { return }
        lastView = (size, displayScale)
        requestDetail(visibleIn: size)
        let full = needsFullResolution(displayScale: displayScale)
        // Panning within the same block of regions at the same resolution needs nothing new; this
        // runs on every frame of a pan.
        guard let range = viewport.visibleRegionRange(in: size) else { return }
        guard range != lastRequest?.range || full != lastRequest?.full else { return }
        lastRequest = (range, full)
        let visible = viewport.visibleRegions(in: size, among: availableRegions)
        let previousVisible = visibleRegions, previousSources = shadowSources
        visibleRegions = Set(visible)
        wantsFullResolution = full
        // Keep both sides for the light's changing east/west direction. A clock update then
        // uses these immutable heights without starting any terrain read.
        shadowSources = !castsShadows || style == .height ? [] : visible.reduce(into: Set<RegionPosition>()) {
            $0.formUnion(MapShadow.retainedSources(for: $1, savedTime: lighting != nil).intersection(availableRegions))
        }
        shadowHeights = shadowHeights.filter { shadowSources.contains($0.key) }
        shadowImages = shadowImages.filter { visibleRegions.contains($0.key) }
        if previousVisible != visibleRegions || previousSources != shadowSources { invalidateShadows() }
        let requested = visible + shadowSources.subtracting(visibleRegions).sorted {
            viewport.distanceToCenter($0) < viewport.distanceToCenter($1)
        }
        let needed = requested.filter { region in
            guard availableRegions.contains(region), !failed.contains(region) else { return false }
            if stale.contains(region) || (shadowSources.contains(region) && shadowHeights[region] == nil) { return true }
            return visibleRegions.contains(region) && (full ? tiles[region] == nil : previews[region] == nil)
        }
        // Keep rendering regions that are still needed; cancel only those that left the view, so a
        // pan doesn't throw away half-decoded regions and start them again.
        let neededSet = Set(needed)
        for (region, job) in inFlight where !neededSet.contains(region) {
            job.task.cancel()
            inFlight[region] = nil
        }
        queue = needed.filter { inFlight[$0] == nil }
        startQueued()
        updateLoadingState()
    }

    private struct Job {
        var id: Int
        var task: Task<Void, Never>
    }

    /// Regions waiting to render, nearest to the view center first.
    private var queue: [RegionPosition] = []
    private var inFlight: [RegionPosition: Job] = [:]
    private var nextJobID = 0
    var isClosed: Bool { renderWork.isClosed }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private func startQueued() {
        while !isClosed, inFlight.count < regionConcurrency, !queue.isEmpty {
            let region = queue.removeFirst()
            let renderer = currentRenderer
            nextJobID += 1
            let id = nextJobID, render = renderTile
            guard let task = renderWork.start(priority: nil, operation: { [weak self] in
                // Await into a local before using `region` again: Swift 6.4 release builds miscompile
                // `(region, try await …, true)` so `region` reads back as (0, 0) after the suspension
                // (fahlman/Chunksee#6 has a standalone reproduction).
                let result: Result<RegionTileRenderer.RenderedTile?, any Error>
                do {
                    let tile = try await render(renderer, region)
                    result = .success(tile)
                } catch {
                    result = .failure(error)
                }
                self?.finish(region, job: id, with: result)
            }) else { return }
            inFlight[region] = Job(id: id, task: task)
        }
    }

    private func finish(_ region: RegionPosition, job id: Int, with result: Result<RegionTileRenderer.RenderedTile?, any Error>) {
        // A job cancelled because its region left the view was already removed (and may have been
        // replaced by a newer job for the same region); its result is dropped.
        guard inFlight[region]?.id == id else { return }
        inFlight[region] = nil
        guard !isClosed else {
            queue = []
            updateLoadingState()
            return
        }
        switch result {
        case .success(let tile?):
            store(tile, for: region)
            if let operation = tile.cacheWrite {
                let write = writeCache
                cacheWork.start(priority: .utility) {
                    if !Task.isCancelled { await write(operation) }
                }
            }
        case .success(nil):
            failed.insert(region)  // no region file any more
        case .failure(let error):
            // Unreadable regions aren't retried during this session.
            if !(error is CancellationError) { failed.insert(region) }
        }
        startQueued()
        updateLoadingState()
    }

    private func updateLoadingState() {
        if inFlight.isEmpty, queue.isEmpty { startShadowsIfNeeded() }
        isLoading = !inFlight.isEmpty || !queue.isEmpty || detailJob != nil || !detailQueue.isEmpty || detailLoadJob != nil || shadowJob != nil
        guard !isLoading else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private var lastRequest: (range: MapViewport.RegionRange, full: Bool)?
    /// The view size and pixel density of the last request, to request again after the world changes.
    private var lastView: (size: CGSize, displayScale: CGFloat)?
    /// The size and pixel density the map is shown at, once it has been laid out.
    var shownSize: (size: CGSize, displayScale: CGFloat)? { lastView }
    /// Regions the game saved since their tiles were drawn. Their old images stay on screen until
    /// the new ones are ready, so a redraw doesn't flicker.
    private var stale: Set<RegionPosition> = []

    /// Redraws regions whose files the game saved, and shows regions it just created.
    func regionsChanged(_ regions: Set<RegionPosition>? = nil) {
        // A directory notification has no individual file names. Include the old set so deleted
        // regions are removed too, and the current set so newly created regions become visible.
        let regions = regions ?? availableRegions.union(dimension.regionFiles().map { RegionPosition(x: $0.x, z: $0.z) })
        for region in regions {
            let file = dimension.regionURL(.terrain, x: region.x, z: region.z)
            if FileManager.default.fileExists(atPath: file.path) { availableRegions.insert(region) } else { availableRegions.remove(region) }
        }
        let affected = currentRenderer.samplesNeighborBiomes
            ? regions.reduce(into: Set<RegionPosition>()) { $0.formUnion(RegionTileRenderer.neighboringRegions(around: $1)) }
            : regions
        for region in affected {
            // Border colors may have read the changed file even when this tile's own file did not change.
            inFlight[region]?.task.cancel()
            inFlight[region] = nil
            shadowHeights[region] = nil
        }
        invalidateDetail(in: affected, keepingImages: true)
        let removed = affected.subtracting(availableRegions)
        invalidateDetail(in: removed, keepingImages: false)
        for region in removed { detailSurfaces[region] = nil }
        if !affected.isDisjoint(with: shadowSources) { invalidateShadows() }
        failed.subtract(affected)
        forgetTopBlocks(in: regions)
        stale.formUnion(affected.filter { tiles[$0] != nil || previews[$0] != nil })
        lastRequest = nil
        if let lastView { requestTiles(visibleIn: lastView.size, displayScale: lastView.displayScale) }
    }

    /// Regions in the view at the last request; never evicted.
    private var visibleRegions: Set<RegionPosition> = []
    /// Whether the last request needed full-resolution tiles. When it didn't, rendered full tiles
    /// are dropped and only previews kept: fully zoomed out, keeping both cost about 1 GB.
    private var wantsFullResolution = true

    /// Waits until every requested tile has been rendered, or loading was cancelled.
    func waitUntilIdle() async {
        while isLoading {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func store(_ tile: RegionTileRenderer.RenderedTile, for region: RegionPosition) {
        let wasStale = stale.remove(region) != nil
        if shadowSources.contains(region), let heights = tile.heights {
            shadowHeights[region] = heights
            shadowsNeedUpdate = true
        }
        if wantsFullResolution {
            invalidateDetail(in: [region], keepingImages: false)
            tiles[region] = tile.full
            if viewport.scale >= MapDetailRenderer.minimumScale, visibleRegions.contains(region), gameArtwork != nil, style != .height {
                detailSurfaces[region] = tile.detail
            }
        } else if wasStale {
            tiles[region] = nil   // drawn from the old file; zooming in will draw it again
            invalidateDetail(in: [region], keepingImages: false)
            detailSurfaces[region] = nil
        }
        previews[region] = tile.preview
        evictFullTiles()
        for region in Self.regionsToEvict(from: previews, keeping: maxPreviews, visible: visibleRegions, viewport: viewport) {
            previews[region] = nil
        }
        if let lastView { requestDetail(visibleIn: lastView.size) }
    }

    private func evictFullTiles() {
        let tileBytes = RegionTileRenderer.side * RegionTileRenderer.side * 4
        let shadowBytes = shadowHeights.values.reduce(0) { $0 + $1.count * MemoryLayout<Int32>.stride }
            + shadowImages.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        let evicted = Self.regionsToEvict(from: tiles, keeping: maxTiles, visible: visibleRegions, viewport: viewport,
            reservedUnits: Double(shadowBytes) / Double(tileBytes),
            additionalUnits: { Double(detailSurfaces[$0]?.estimatedBytes ?? 0) / Double(tileBytes) })
        for region in evicted {
            tiles[region] = nil
            detailSurfaces[region] = nil
            invalidateDetail(in: [region], keepingImages: false)
        }
    }

    /// The cached regions farthest from the view center beyond `limit`, never a visible one.
    private static func regionsToEvict(from cached: [RegionPosition: MapTileImage], keeping limit: Int,
                                       visible: Set<RegionPosition>, viewport: MapViewport,
                                       reservedUnits: Double = 0,
                                       additionalUnits: (RegionPosition) -> Double = { _ in 0 }) -> [RegionPosition] {
        var units = reservedUnits + cached.reduce(0.0) { $0 + Double($1.value.storageUnits) + additionalUnits($1.key) }
        guard units > Double(limit) else { return [] }
        let candidates = Set(cached.keys).subtracting(visible)
            .sorted { viewport.distanceToCenter($0) > viewport.distanceToCenter($1) }
        var evicted: [RegionPosition] = []
        for region in candidates where units > Double(limit) {
            units -= Double(cached[region]?.storageUnits ?? 0) + additionalUnits(region)
            evicted.append(region)
        }
        return evicted
    }

    func cancel() {
        lastRequest = nil
        renderWork.cancel()
        inFlight = [:]
        queue = []
        detailWork.cancel()
        detailJob = nil
        detailQueue = []
        detailLoadJob = nil
        detailRegionsWanted = []
        invalidateShadows()
        shadowsNeedUpdate = false
        updateLoadingState()
    }

    func waitForRenders() async {
        await work.waitUntilFinished(in: [renderWork, cacheWork, readoutWork, coordinateWork, detailWork, shadowWork])
    }

    func close() {
        renderWork.close()
        readoutWork.close()
        activeTopBlockReads = [:]
        hoveredChunk = nil
        coordinateWork.close()
        cacheWork.close()
        detailWork.close()
        detailSurfaces = [:]
        detailImages = [:]
        detailAttempted = []
        detailLoadsAttempted = []
        shadowWork.close()
        cancel()
        shadowHeights = [:]
        shadowImages = [:]
        gameData = nil
        gameArtwork = nil
        biomeColors = nil
        nightLighting = nil
    }

    // MARK: Close-up terrain

    private func requestDetail(visibleIn size: CGSize) {
        guard !isClosed else { return }
        let enabled = viewport.scale >= MapDetailRenderer.minimumScale && gameArtwork != nil && style != .height
        detailRegionsWanted = enabled
            ? Set(viewport.visibleRegions(in: size, among: availableRegions).filter { tiles[$0] != nil && !stale.contains($0) }) : []
        detailSurfaces = detailSurfaces.filter { detailRegionsWanted.contains($0.key) }
        detailLoadsAttempted.formIntersection(detailRegionsWanted)
        if let job = detailLoadJob, !detailRegionsWanted.contains(job.region) {
            job.task.cancel()
            detailLoadJob = nil
        }
        if !enabled {
            detailImages = [:]
            detailAttempted = []
        }
        let visible = Set(detailSurfaces.flatMap { region, surface in
            MapDetailRenderer.visibleChunks(in: surface, region: region, viewport: viewport, size: size)
        })
        let needed = gameArtwork == nil ? [] : visible.filter {
            !stale.contains($0.region) && !detailAttempted.contains($0)
        }
        if let job = detailJob, !needed.contains(job.chunk) {
            job.task.cancel()
            detailJob = nil
        }
        let center = viewport.center
        detailQueue = needed.filter { $0 != detailJob?.chunk }.sorted {
            func distance(_ chunk: ChunkPosition) -> CGFloat {
                guard let origin = chunk.blockOrigin else { return .greatestFiniteMagnitude }
                return hypot(CGFloat(origin.x) + 8 - center.x, CGFloat(origin.z) + 8 - center.y)
            }
            let first = distance($0), second = distance($1)
            if first != second { return first < second }
            return $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x
        }
        trimDetailCache()
        startDetailLoad()
        startDetail()
        updateLoadingState()
    }

    private func startDetailLoad() {
        guard !isClosed, detailLoadJob == nil, let lastView,
              let region = viewport.visibleRegions(in: lastView.size, among: detailRegionsWanted).first(where: {
                  detailSurfaces[$0] == nil && !detailLoadsAttempted.contains($0)
              }) else { return }
        let id = UUID(), reader = readDetail, renderer = currentRenderer, work = work, cacheWork = cacheWork
        guard let task = detailWork.start(priority: nil, operation: { [weak self] in
            // A just-rendered ordinary tile may still be writing its sidecar. Finish accepted
            // writes before loading, so zooming cannot cause a redundant world read.
            await work.waitUntilFinished(in: [cacheWork])
            let surface: MapSurfaceDetail.Surface?
            do {
                try Task.checkCancellation()
                surface = try await reader(renderer, region)
            } catch { surface = nil }
            guard let self, self.detailLoadJob?.id == id, !self.isClosed else { return }
            self.detailLoadJob = nil
            if !Task.isCancelled {
                self.detailSurfaces[region] = surface
                self.detailLoadsAttempted.insert(region)
                self.evictFullTiles()
            }
            if let view = self.lastView { self.requestDetail(visibleIn: view.size) }
        }) else { return }
        detailLoadJob = (region: region, id: id, task: task)
    }

    private func trimDetailCache() {
        // Count unavailable results as well as pictures, including old pictures retained during
        // a live save. Check after publication too, so the budget does not rely on another pan.
        let retained = detailAttempted.union(detailImages.keys)
        guard retained.count > 256 else { return }
        let range = viewport.scale >= MapDetailRenderer.minimumScale
            ? lastView.flatMap { viewport.visibleChunkRange(in: $0.size) } : nil
        let removable = retained.filter { chunk in
            guard let range else { return true }
            return !range.xs.contains(chunk.x) || !range.zs.contains(chunk.z)
        }.sorted { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }
        for chunk in removable.prefix(retained.count - 256) {
            detailAttempted.remove(chunk)
            detailImages[chunk] = nil
        }
    }

    private func startDetail() {
        guard !isClosed, detailJob == nil, !detailQueue.isEmpty, let assets = gameArtwork else { return }
        let chunk = detailQueue.removeFirst()
        guard let surface = detailSurfaces[chunk.region] else { return }
        let id = UUID(), render = renderDetail, heightScale = heightScale, usesSavedLighting = lighting != nil
        guard let task = detailWork.start(priority: nil, operation: { [weak self] in
            let image: MapTileImage?
            do { image = try await render(chunk, surface, assets, heightScale, usesSavedLighting) }
            catch { image = nil }
            guard let self, self.detailJob?.id == id, !self.isClosed else { return }
            self.detailJob = nil
            if !Task.isCancelled {
                self.detailImages[chunk] = image
                self.detailAttempted.insert(chunk)
                self.trimDetailCache()
            }
            self.startDetail()
            self.updateLoadingState()
        }) else { return }
        detailJob = (chunk, id, task)
    }

    private func invalidateDetail(in regions: Set<RegionPosition>, keepingImages: Bool) {
        if let job = detailLoadJob, regions.contains(job.region) {
            job.task.cancel()
            detailLoadJob = nil
        }
        detailLoadsAttempted.subtract(regions)
        detailSurfaces = detailSurfaces.filter { !regions.contains($0.key) }
        if let job = detailJob, regions.contains(job.chunk.region) {
            job.task.cancel()
            detailJob = nil
        }
        detailQueue.removeAll { regions.contains($0.region) }
        detailAttempted = detailAttempted.filter { !regions.contains($0.region) }
        if !keepingImages { detailImages = detailImages.filter { !regions.contains($0.key.region) } }
    }

    // MARK: Blocks for the pointer and centered accessibility readout

    typealias TopBlockRead = (file: RegionFile, blocks: [RegionTileRenderer.TopBlock?])

    /// The top block of each column (index `z * 16 + x`) in recently requested chunks. The pointer
    /// and centered accessibility readout share these columns rather than decoding them twice.
    private(set) var topBlocks: [ChunkPosition: [RegionTileRenderer.TopBlock?]] = [:]
    @ObservationIgnored private var topBlockOrder: [ChunkPosition] = []
    /// The chunk under the pointer, so a save of its region can be read again without the pointer moving.
    @ObservationIgnored private var hoveredChunk: ChunkPosition?
    @ObservationIgnored private var activeTopBlockReads: [ChunkPosition: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Bumped when the game saves a region, so a read of the old file doesn't publish after it.
    @ObservationIgnored private var regionGenerations: [RegionPosition: Int] = [:]
    /// The region file last read for either readout, reused for another chunk in that region.
    @ObservationIgnored private var readoutRegion: RegionFile?
    typealias TopBlockReader = @Sendable (ChunkPosition, RegionTileRenderer, RegionFile?) async -> TopBlockRead?
    @ObservationIgnored private let readTopBlocksFor: TopBlockReader
    private static let maxReadoutChunks = 64

    /// Readout reads not yet finished, cancelled or not.
    var unfinishedTopBlockReads: Int { readoutWork.unfinishedCount }
    var unfinishedCoordinateReads: Int { coordinateWork.unfinishedCount }

    /// The block the map shows at a world block, once its chunk has been read.
    func topBlock(at block: CGPoint) -> RegionTileRenderer.TopBlock? {
        guard let coordinates = MapCoordinates(point: block) else { return nil }
        let x = Int(coordinates.x), z = Int(coordinates.z)
        let chunk = ChunkPosition(containingBlockX: x, blockZ: z)
        return topBlocks[chunk]?[ChunkPosition.localColumnIndex(blockX: x, blockZ: z)] ?? nil
    }

    /// Uses the same reader and cached columns as hover, while keeping this request independent
    /// of pointer movement. Closing the map cancels and drains every read before access ends.
    func readTopBlock(at block: CGPoint, completion: @escaping (RegionTileRenderer.TopBlock?) -> Void) {
        guard !isClosed, let coordinates = MapCoordinates(point: block) else { return }
        if let cached = topBlock(at: coordinates.position) { completion(cached); return }
        let chunk = ChunkPosition(containingBlockX: Int(coordinates.x), blockZ: Int(coordinates.z))
        let index = ChunkPosition.localColumnIndex(blockX: Int(coordinates.x), blockZ: Int(coordinates.z))
        let renderer = currentRenderer, cached = readoutRegion, read = readTopBlocksFor
        coordinateWork.start(priority: nil) { [weak self] in
            let result = await read(chunk, renderer, cached)
            guard let self else { return }
            guard !Task.isCancelled, !self.isClosed else { return }
            completion(result.flatMap { $0.blocks.indices.contains(index) ? $0.blocks[index] : nil })
        }
    }

    func waitForCoordinateReads() async {
        await coordinateWork.waitUntilFinished()
    }

    private static func chunk(at point: CGPoint) -> ChunkPosition? {
        guard let coordinates = MapCoordinates(point: point) else { return nil }
        return ChunkPosition(containingBlockX: Int(coordinates.x), blockZ: Int(coordinates.z))
    }

    private var readoutChunks: Set<ChunkPosition> {
        var chunks = Set<ChunkPosition>()
        if let hoveredChunk { chunks.insert(hoveredChunk) }
        if showsDarkSpots, let center = Self.chunk(at: viewport.center) { chunks.insert(center) }
        return chunks
    }

    /// Reads the pointer's chunk off the main actor, sharing a pending/cached center read.
    func loadTopBlocks(at block: CGPoint) {
        guard !isClosed, let chunk = Self.chunk(at: block) else { return }
        hoveredChunk = chunk
        updateTopBlockReads()
    }

    func endHover() {
        hoveredChunk = nil
        updateTopBlockReads()
    }

    /// At most two chunks are wanted. Moving either readout cancels only work neither needs.
    private func updateTopBlockReads() {
        guard !isClosed else { return }
        let wanted = readoutChunks
        for (chunk, active) in activeTopBlockReads where !wanted.contains(chunk) {
            active.task.cancel()
            activeTopBlockReads[chunk] = nil
        }
        for chunk in wanted where topBlocks[chunk] == nil && activeTopBlockReads[chunk] == nil {
            startTopBlockRead(of: chunk)
        }
    }

    private func startTopBlockRead(of chunk: ChunkPosition) {
        let region = chunk.region, generation = regionGenerations[region, default: 0], id = UUID()
        let renderer = currentRenderer, cached = readoutRegion, read = readTopBlocksFor
        guard let task = readoutWork.start(priority: nil, operation: { [weak self] in
            let result = await read(chunk, renderer, cached)
            guard let self, self.activeTopBlockReads[chunk]?.id == id else { return }
            self.activeTopBlockReads[chunk] = nil
            // A read cancelled for another chunk, or of a file the game has since saved, isn't kept.
            guard let result, !Task.isCancelled, !self.isClosed, self.regionGenerations[region, default: 0] == generation else { return }
            self.readoutRegion = result.file
            self.topBlocks[chunk] = result.blocks
            self.topBlockOrder.append(chunk)
            if self.topBlockOrder.count > Self.maxReadoutChunks,
               let index = self.topBlockOrder.firstIndex(where: { !self.readoutChunks.contains($0) }) {
                self.topBlocks[self.topBlockOrder.remove(at: index)] = nil
            }
        }) else { return }
        activeTopBlockReads[chunk] = (id, task)
    }

    /// Waits for every readout read, including cancelled ones still finishing.
    func waitForTopBlocks() async {
        await readoutWork.waitUntilFinished()
    }

    @concurrent
    nonisolated static func readTopBlocks(of chunk: ChunkPosition, using renderer: RegionTileRenderer,
                                          cached: RegionFile?) async -> TopBlockRead? {
        guard !Task.isCancelled else { return nil }   // before any file I/O
        let region = chunk.region
        guard let file = cached.flatMap({ $0.x == region.x && $0.z == region.z ? $0 : nil })
                ?? (try? renderer.dimension.region(x: region.x, z: region.z)) ?? nil,
              !Task.isCancelled,
              let blocks = RegionTileRenderer.topBlocks(in: file, localX: chunk.localX, localZ: chunk.localZ,
                                                       context: renderer.surfaceContext, cutawayY: renderer.cutawayY, blockFilter: renderer.blockFilter,
                                                       darkSpots: renderer.darkSpots)
        else { return nil }
        return (file, blocks)
    }

    /// The game saved these regions, so what was read from them may be out of date. A read elsewhere
    /// carries on; the pointer and center are read again without waiting for either to move.
    private func forgetTopBlocks(in regions: Set<RegionPosition>) {
        func changed(_ chunk: ChunkPosition) -> Bool { regions.contains(chunk.region) }
        for region in regions { regionGenerations[region, default: 0] += 1 }
        topBlocks = topBlocks.filter { !changed($0.key) }
        topBlockOrder.removeAll(where: changed)
        if let file = readoutRegion, regions.contains(RegionPosition(x: file.x, z: file.z)) { readoutRegion = nil }
        for (chunk, active) in activeTopBlockReads where changed(chunk) {
            active.task.cancel()
            activeTopBlockReads[chunk] = nil
        }
        updateTopBlockReads()
    }

    /// A selected location supplies a height without switching Surface/Cutaway mode.
    func setHeight(_ y: Int) {
        setDepth(MapDepth(y: y, isSurface: depth.isSurface))
    }

    /// A height command enters Cutaway so each step changes the displayed map, even from Surface.
    func stepHeight(by step: Int) {
        let (y, overflow) = depth.y.addingReportingOverflow(step)
        guard !overflow else { return }
        setDepth(MapDepth(y: y, isSurface: false))
    }

    /// A depth change invalidates pixels and named columns together. Cancelled tasks remain
    /// tracked for close/drain, but their old job IDs and cancellation prevent publication.
    func setDepth(_ value: MapDepth) {
        guard !isClosed, value != depth else { return }
        let previous = depth.cutawayY
        depth = value
        guard previous != value.cutawayY else { return }
        surfaceChanged()
    }

    func setDimensionSettings(_ settings: DimensionSettings?, water: GameTag?) {
        let context = MapSurfaceContext(settings: settings, water: water)
        let scale = MapHeightScale(settings: settings)
        guard !isClosed, context != renderer.surfaceContext || scale != heightScale else { return }
        renderer.surfaceContext = context
        renderer.heightScale = scale
        heightScale = scale
        if scale == nil, style == .height { style = .normal }
        surfaceChanged()
    }

    /// Changing a hidden block can change its Y as well as its colour. Late reads of the previous
    /// surface must never publish hover details or copy coordinates after applying new choices.
    func setBlockFilter(_ value: MapBlockFilter) {
        guard !isClosed, value != blockFilter else { return }
        let previous = blockFilter
        blockFilter = value
        guard previous.cacheKey != value.cacheKey else { return }
        if previous.effectiveHiddenIDs != value.effectiveHiddenIDs { surfaceChanged() }
        else { reloadTiles() }
    }

    func setDarkSpots(_ shown: Bool) {
        guard !isClosed, showsDarkSpots != shown else { return }
        showsDarkSpots = shown
        surfaceChanged(coordinatesChanged: false)
    }

    func setNightLighting(_ value: MonsterSpawnLight?) {
        guard !isClosed, nightLighting != value else { return }
        nightLighting = value
        if showsDarkSpots { surfaceChanged(coordinatesChanged: false) }
    }

    private func surfaceChanged(coordinatesChanged: Bool = true) {
        readoutWork.cancel()
        if coordinatesChanged { coordinateWork.cancel() }
        activeTopBlockReads = [:]
        topBlocks = [:]
        topBlockOrder = []
        readoutRegion = nil
        reloadTiles()
        updateTopBlockReads()
    }

    /// A style changes colours, never the selected block or a pending coordinate/hover read.
    func setStyle(_ value: MapStyle) {
        guard !isClosed, value != style, value != .height || heightScale != nil else { return }
        style = value
        reloadTiles()
    }

    func setBiomeBlending(_ enabled: Bool) {
        guard !isClosed, enabled != blendsBiomeColors else { return }
        blendsBiomeColors = enabled
        if style != .height { reloadTiles() }
    }

    /// Time changes only the drawing snapshot. Rebuild image inputs from the unlit disk cache
    /// when availability or the chosen mode changes; clock ticks never invalidate terrain.
    func setSavedLighting(_ value: MapLighting?) {
        guard !isClosed, value != savedLighting else { return }
        let prepared = lighting != nil, previousLight = shadowLight
        savedLighting = value
        if prepared != (lighting != nil) { reloadTiles() }
        else if previousLight != shadowLight { invalidateShadows(); updateLoadingState() }
    }

    func setLightingMode(_ value: MapLightingMode) {
        guard !isClosed, value != lightingMode else { return }
        let prepared = lighting != nil, previousLight = shadowLight
        lightingMode = value
        if prepared != (lighting != nil) { reloadTiles() }
        else if previousLight != shadowLight { invalidateShadows(); updateLoadingState() }
    }

    func setCastsShadows(_ value: Bool) {
        guard !isClosed, value != castsShadows else { return }
        castsShadows = value
        invalidateShadows()
        if !value { shadowImages = [:]; shadowHeights = [:]; shadowSources = [] }
        lastRequest = nil
        if let lastView { requestTiles(visibleIn: lastView.size, displayScale: lastView.displayScale) }
        updateLoadingState()
    }

    private func invalidateShadows() {
        shadowRevision += 1
        shadowJob?.cancel()
        shadowJob = nil
        shadowsNeedUpdate = true
    }

    private func startShadowsIfNeeded() {
        guard !isClosed, shadowJob == nil, shadowsNeedUpdate else { return }
        shadowsNeedUpdate = false
        guard let light = shadowLight, !visibleRegions.isEmpty else { shadowImages = [:]; return }
        let sources = shadowHeights, regions = visibleRegions, revision = shadowRevision
        shadowJob = shadowWork.start(priority: .utility) { [weak self] in
            defer {
                if let self, self.shadowRevision == revision {
                    self.shadowJob = nil
                    self.updateLoadingState()
                }
            }
            var images: [RegionPosition: CGImage] = [:]
            do {
                for region in regions {
                    try Task.checkCancellation()
                    if let image = try await MapShadow.image(for: region, heights: sources, light: light) {
                        images[region] = image
                    }
                }
                guard let self, !self.isClosed, !Task.isCancelled, self.shadowRevision == revision else { return }
                self.shadowImages = images
                self.evictFullTiles()
            } catch { /* Cancellation leaves the last complete drawing until its replacement is ready. */ }
        }
    }

    /// Data remains connected when artwork changes. Retire old drawing requests and keys
    /// without changing the selected world facts or their immutable reader.
    func setGameResources(data: GameDataLibrary?, artwork: GameArtworkLibrary?, biomeColors: MapBiomeColors? = nil) {
        guard !isClosed, gameData?.identity != data?.identity || gameArtwork?.identity != artwork?.identity
                || self.biomeColors?.sourceKey != biomeColors?.sourceKey else { return }
        gameData = data
        gameArtwork = artwork
        self.biomeColors = biomeColors
        if style != .height { reloadTiles() }
    }

    private func reloadTiles() {
        clearRenderedTiles()
        if let lastView { requestTiles(visibleIn: lastView.size, displayScale: lastView.displayScale) }
    }

    private func clearRenderedTiles() {
        cancel()
        tiles = [:]
        detailSurfaces = [:]
        detailImages = [:]
        detailAttempted = []
        detailLoadsAttempted = []
        previews = [:]
        shadowHeights = [:]
        shadowImages = [:]
        failed = []
        stale = []
    }

    func zoom(by factor: CGFloat) {
        viewport.zoom(by: factor)
    }
}
