import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// Tiles and viewport for one dimension's top-down map.
@Observable
final class MapModel {
    let dimension: ChunkseeKit.Dimension
    var viewport: MapViewport
    private(set) var depth = MapDepth()

    /// Full-resolution tiles (512×512), kept for the regions near the view.
    private(set) var tiles: [RegionPosition: CGImage] = [:]
    /// Half-resolution previews (256×256, a quarter of the memory), kept for many more regions so
    /// zoomed-out views never thrash and zooming in shows something at once.
    private(set) var previews: [RegionPosition: CGImage] = [:]
    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionPosition>
    private(set) var isLoading = false

    private var failed: Set<RegionPosition> = []
    private let renderer: RegionTileRenderer
    private let work: BackgroundWork
    private let renderWork, cacheWork, hoverWork, coordinateWork: BackgroundWork.Scope
    @ObservationIgnored private let writeCache: @Sendable (RegionTileRenderer.CacheWrite) async -> Void
    var unfinishedCacheWrites: Int { cacheWork.unfinishedCount }
    @ObservationIgnored private let renderTile: @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
    /// At 1 MB per tile and 256 KB per preview, about 200 MB each. Visible tiles are never evicted,
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
         writeCache: @escaping @Sendable (RegionTileRenderer.CacheWrite) async -> Void = { await $0.store() },
         renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
            = { try await $0.tile(for: $1) },
         readTopBlocks: @escaping @Sendable (ChunkPosition, ChunkseeKit.Dimension, MapDepth, RegionFile?) async -> TopBlockRead?
            = { await MapModel.readTopBlocks(of: $0, in: $1, depth: $2, cached: $3) }) {
        self.work = work
        renderWork = work.makeScope()
        cacheWork = work.makeScope()
        hoverWork = work.makeScope()
        coordinateWork = work.makeScope()
        self.dimension = dimension
        self.readTopBlocksFor = readTopBlocks
        self.renderTile = renderTile
        self.writeCache = writeCache
        self.maxTiles = maxTiles
        self.maxPreviews = maxPreviews
        self.regionConcurrency = max(1, regionConcurrency)
        self.renderer = RegionTileRenderer(dimension: dimension, chunkConcurrency: max(1, chunkConcurrency),
                                           cache: cacheDirectory.map(TileCache.init(directory:)))
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionPosition(x: $0.x, z: $0.z) })
    }

    /// Whether the view shows regions large enough on screen to need full-resolution tiles:
    /// more than a preview's 256 pixels, at the display's pixel density.
    func needsFullResolution(displayScale: CGFloat) -> Bool {
        viewport.scale * CGFloat(RegionTileRenderer.side) * displayScale > CGFloat(RegionTileRenderer.previewSide)
    }

    /// The image to draw for a region: the sharpest one cached that the view needs.
    func image(for region: RegionPosition, fullResolution: Bool) -> CGImage? {
        fullResolution ? (tiles[region] ?? previews[region]) : (previews[region] ?? tiles[region])
    }

    /// Starts rendering the visible regions that lack the resolution the view needs, nearest to the
    /// center first. A new request replaces the previous one, so panning away cancels work that's
    /// no longer visible.
    func requestTiles(visibleIn size: CGSize, displayScale: CGFloat = 2) {
        guard !isClosed, size.width > 0, size.height > 0 else { return }
        lastView = (size, displayScale)
        let full = needsFullResolution(displayScale: displayScale)
        // Panning within the same block of regions at the same resolution needs nothing new; this
        // runs on every frame of a pan.
        guard let range = viewport.visibleRegionRange(in: size) else { return }
        guard range != lastRequest?.range || full != lastRequest?.full else { return }
        lastRequest = (range, full)
        let visible = viewport.visibleRegions(in: size, among: availableRegions)
        visibleRegions = Set(visible)
        wantsFullResolution = full
        let needed = visible.filter {
            availableRegions.contains($0) && !failed.contains($0) && ((full ? tiles[$0] == nil : previews[$0] == nil) || stale.contains($0))
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
    private var isClosed: Bool { renderWork.isClosed }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private func startQueued() {
        while !isClosed, inFlight.count < regionConcurrency, !queue.isEmpty {
            let region = queue.removeFirst()
            var renderer = renderer
            renderer.cutawayY = depth.cutawayY
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
        isLoading = !inFlight.isEmpty || !queue.isEmpty
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
            // A render that started before the save may have read the old file; start it again.
            inFlight[region]?.task.cancel()
            inFlight[region] = nil
        }
        failed.subtract(regions)
        forgetTopBlocks(in: regions)
        stale.formUnion(regions.filter { tiles[$0] != nil || previews[$0] != nil })
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
        if wantsFullResolution {
            tiles[region] = tile.full
        } else if wasStale {
            tiles[region] = nil   // drawn from the old file; zooming in will draw it again
        }
        previews[region] = tile.preview
        for region in Self.regionsToEvict(from: Set(tiles.keys), keeping: maxTiles, visible: visibleRegions, viewport: viewport) {
            tiles[region] = nil
        }
        for region in Self.regionsToEvict(from: Set(previews.keys), keeping: maxPreviews, visible: visibleRegions, viewport: viewport) {
            previews[region] = nil
        }
    }

    /// The cached regions farthest from the view center beyond `limit`, never a visible one.
    private static func regionsToEvict(from cached: Set<RegionPosition>, keeping limit: Int,
                                       visible: Set<RegionPosition>, viewport: MapViewport) -> [RegionPosition] {
        guard cached.count > limit else { return [] }
        let candidates = cached.subtracting(visible)
            .sorted { viewport.distanceToCenter($0) > viewport.distanceToCenter($1) }
        return Array(candidates.prefix(cached.count - limit))
    }

    func cancel() {
        lastRequest = nil
        renderWork.cancel()
        inFlight = [:]
        queue = []
        updateLoadingState()
    }

    func waitForRenders() async {
        await work.waitUntilFinished(in: [renderWork, cacheWork, hoverWork, coordinateWork])
    }

    func close() {
        renderWork.close()
        hoverWork.close()
        coordinateWork.close()
        cacheWork.close()
        cancel()
    }

    // MARK: The hover readout's block

    typealias TopBlockRead = (file: RegionFile, blocks: [RegionTileRenderer.TopBlock?])

    /// The top block of each column (index `z * 16 + x`) in recently hovered chunks, read on demand.
    /// Tiles keep only colors, and naming every column of every region would cost far more than
    /// reading the one chunk under the pointer.
    private(set) var topBlocks: [ChunkPosition: [RegionTileRenderer.TopBlock?]] = [:]
    @ObservationIgnored private var topBlockOrder: [ChunkPosition] = []
    /// The chunk under the pointer, so a save of its region can be read again without the pointer moving.
    @ObservationIgnored private var hoveredChunk: ChunkPosition?
    /// The read for the hovered chunk, if one is under way.
    @ObservationIgnored private var activeHoverRead: (chunk: ChunkPosition, id: UUID, task: Task<Void, Never>)?
    /// Bumped when the game saves a region, so a read of the old file doesn't publish after it.
    @ObservationIgnored private var regionGenerations: [RegionPosition: Int] = [:]
    /// The region file last read for the readout, reused while the pointer stays in its region.
    @ObservationIgnored private var hoverRegion: RegionFile?
    @ObservationIgnored private let readTopBlocksFor: @Sendable (ChunkPosition, ChunkseeKit.Dimension, MapDepth, RegionFile?) async -> TopBlockRead?
    private static let maxHoverChunks = 64

    /// Hover reads not yet finished, cancelled or not.
    var unfinishedHoverReads: Int { hoverWork.unfinishedCount }
    var unfinishedCoordinateReads: Int { coordinateWork.unfinishedCount }

    /// The block the map shows at a world block, once its chunk has been read.
    func topBlock(at block: CGPoint) -> RegionTileRenderer.TopBlock? {
        guard let coordinates = MapCoordinates(point: block) else { return nil }
        let x = Int(coordinates.x), z = Int(coordinates.z)
        return topBlocks[ChunkPosition(x: x >> 4, z: z >> 4)]?[(z & 15) * 16 + (x & 15)] ?? nil
    }

    /// Uses the same reader and cached columns as hover, while keeping this request independent
    /// of pointer movement. Closing the map cancels and drains every read before access ends.
    func readTopBlock(at block: CGPoint, completion: @escaping (RegionTileRenderer.TopBlock?) -> Void) {
        guard !isClosed, let coordinates = MapCoordinates(point: block) else { return }
        if let cached = topBlock(at: coordinates.position) { completion(cached); return }
        let chunk = ChunkPosition(x: Int(coordinates.x) >> 4, z: Int(coordinates.z) >> 4)
        let index = (Int(coordinates.z) & 15) * 16 + (Int(coordinates.x) & 15)
        let dimension = dimension, depth = depth, cached = hoverRegion, read = readTopBlocksFor
        coordinateWork.start(priority: nil) { [weak self] in
            let result = await read(chunk, dimension, depth, cached)
            guard let self else { return }
            guard !Task.isCancelled, !self.isClosed else { return }
            completion(result.flatMap { $0.blocks.indices.contains(index) ? $0.blocks[index] : nil })
        }
    }

    func waitForCoordinateReads() async {
        await coordinateWork.waitUntilFinished()
    }

    /// Reads the chunk under the pointer off the main actor, unless it's read or being read. Only
    /// that chunk matters, so a read for one the pointer has left is cancelled.
    func loadTopBlocks(at block: CGPoint) {
        guard !isClosed, let coordinates = MapCoordinates(point: block) else { return }
        let chunk = ChunkPosition(x: Int(coordinates.x) >> 4, z: Int(coordinates.z) >> 4)
        hoveredChunk = chunk
        guard topBlocks[chunk] == nil, activeHoverRead?.chunk != chunk else { return }
        startHoverRead(of: chunk)
    }

    /// The pointer left the map: nothing needs reading again after a save.
    func endHover() { hoveredChunk = nil }

    private func startHoverRead(of chunk: ChunkPosition) {
        activeHoverRead?.task.cancel()
        let region = chunk.region, generation = regionGenerations[region, default: 0], id = UUID()
        let dimension = dimension, depth = depth, cached = hoverRegion, read = readTopBlocksFor
        guard let task = hoverWork.start(priority: nil, operation: { [weak self] in
            let result = await read(chunk, dimension, depth, cached)
            guard let self else { return }
            if self.activeHoverRead?.id == id { self.activeHoverRead = nil }
            // A read cancelled for another chunk, or of a file the game has since saved, isn't kept.
            guard let result, !Task.isCancelled, !self.isClosed, self.regionGenerations[region, default: 0] == generation else { return }
            self.hoverRegion = result.file
            self.topBlocks[chunk] = result.blocks
            self.topBlockOrder.append(chunk)
            if self.topBlockOrder.count > Self.maxHoverChunks { self.topBlocks[self.topBlockOrder.removeFirst()] = nil }
        }) else { return }
        activeHoverRead = (chunk, id, task)
    }

    /// Waits for every hover read, including cancelled ones still finishing.
    func waitForTopBlocks() async {
        await hoverWork.waitUntilFinished()
    }

    @concurrent
    nonisolated static func readTopBlocks(of chunk: ChunkPosition, in dimension: ChunkseeKit.Dimension, depth: MapDepth,
                                          cached: RegionFile?) async -> TopBlockRead? {
        guard !Task.isCancelled else { return nil }   // before any file I/O
        let region = chunk.region
        guard let file = cached.flatMap({ $0.x == region.x && $0.z == region.z ? $0 : nil })
                ?? (try? dimension.region(x: region.x, z: region.z)) ?? nil,
              !Task.isCancelled,
              let blocks = RegionTileRenderer.topBlocks(in: file, localX: chunk.localX, localZ: chunk.localZ, ceilingY: RegionTileRenderer(dimension: dimension).ceilingY, cutawayY: depth.cutawayY)
        else { return nil }
        return (file, blocks)
    }

    /// The game saved these regions, so what was read from them may be out of date. A read elsewhere
    /// carries on; the hovered chunk, if it's in one of them, is read again without waiting for the
    /// pointer to move.
    private func forgetTopBlocks(in regions: Set<RegionPosition>) {
        func changed(_ chunk: ChunkPosition) -> Bool { regions.contains(chunk.region) }
        for region in regions { regionGenerations[region, default: 0] += 1 }
        topBlocks = topBlocks.filter { !changed($0.key) }
        topBlockOrder.removeAll(where: changed)
        if let file = hoverRegion, regions.contains(RegionPosition(x: file.x, z: file.z)) { hoverRegion = nil }
        if let active = activeHoverRead, changed(active.chunk) {
            active.task.cancel()
            activeHoverRead = nil
        }
        if !isClosed, let chunk = hoveredChunk, changed(chunk) { startHoverRead(of: chunk) }
    }

    /// A depth change invalidates pixels and named columns together. Cancelled tasks remain
    /// tracked for close/drain, but their old job IDs and cancellation prevent publication.
    func setDepth(_ value: MapDepth) {
        guard !isClosed, value != depth else { return }
        let previous = depth.cutawayY
        depth = value
        guard previous != value.cutawayY else { return }
        cancel()
        tiles = [:]
        previews = [:]
        failed = []
        stale = []
        hoverWork.cancel()
        coordinateWork.cancel()
        activeHoverRead = nil
        topBlocks = [:]
        topBlockOrder = []
        hoverRegion = nil
        if let lastView { requestTiles(visibleIn: lastView.size, displayScale: lastView.displayScale) }
        if let hoveredChunk { startHoverRead(of: hoveredChunk) }
    }

    func zoom(by factor: CGFloat) {
        viewport.zoom(by: factor)
    }
}
