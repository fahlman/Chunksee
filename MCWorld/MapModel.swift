import CoreGraphics
import Foundation
import MCWorldKit
import Observation

/// Tiles and viewport for one dimension's top-down map.
@Observable
final class MapModel {
    let dimension: MCWorldKit.Dimension
    var viewport: MapViewport

    /// Full-resolution tiles (512×512), kept for the regions near the view.
    private(set) var tiles: [RegionCoordinate: CGImage] = [:]
    /// Half-resolution previews (256×256, a quarter of the memory), kept for many more regions so
    /// zoomed-out views never thrash and zooming in shows something at once.
    private(set) var previews: [RegionCoordinate: CGImage] = [:]
    // Layers, filled in by `loadLayers()`.
    /// Every structure in the dimension's generated chunks.
    private(set) var structures: [StructureMarker] = []
    /// Every point of interest (portals, bells, beds…).
    private(set) var places: [PlaceMarker] = []
    /// Named creatures, pets and villagers.
    private(set) var creatures: [CreatureMarker] = []
    private(set) var biomeAreas: [BiomeArea] = []
    /// The surface biome of every chunk, for the hover readout.
    private var biomes: [ChunkCoordinate: String] = [:]
    private var layerTask: Task<Void, Never>?

    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionCoordinate>
    private(set) var isLoading = false

    private var failed: Set<RegionCoordinate> = []
    private let renderer: RegionTileRenderer
    /// Places saved between launches.
    private let scanCache: ScanCache
    /// Structures, creatures and biomes, read once per region and shared with search and the heat map.
    private let reader: RegionReader

    /// At 1 MB per tile and 256 KB per preview, about 200 MB each. Visible tiles are never evicted,
    /// so a very large window can exceed these rather than show blanks.
    private let maxTiles: Int
    private let maxPreviews: Int
    private let regionConcurrency: Int

    /// Measured on a 14-core M4 Pro (fahlman/MCWorld#3): rendering regions and their chunks one
    /// per core filled every tested view fastest or tied-fastest, and the cooperative thread pool
    /// keeps the total thread count at the core count however many tasks are queued.
    static let defaultConcurrency = ProcessInfo.processInfo.activeProcessorCount

    init(dimension: MCWorldKit.Dimension, center: CGPoint,
         regionConcurrency: Int = MapModel.defaultConcurrency, chunkConcurrency: Int = MapModel.defaultConcurrency,
         maxTiles: Int = 200, maxPreviews: Int = 800, cacheDirectory: URL? = nil, reader: RegionReader? = nil) {
        self.dimension = dimension
        self.maxTiles = maxTiles
        self.maxPreviews = maxPreviews
        self.regionConcurrency = max(1, regionConcurrency)
        self.renderer = RegionTileRenderer(dimension: dimension, chunkConcurrency: max(1, chunkConcurrency),
                                           cache: cacheDirectory.map(TileCache.init(directory:)))
        self.scanCache = ScanCache(directory: cacheDirectory?.appendingPathComponent("scans", isDirectory: true))
        self.reader = reader ?? RegionReader(dimension: dimension, cache: scanCache)
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionCoordinate(x: $0.x, z: $0.z) })
    }

    /// Whether the view shows regions large enough on screen to need full-resolution tiles:
    /// more than a preview's 256 pixels, at the display's pixel density.
    func needsFullResolution(displayScale: CGFloat) -> Bool {
        viewport.scale * CGFloat(RegionCoordinate.blockSize) * displayScale > CGFloat(RegionTileRenderer.previewSide)
    }

    /// The surface biome of the chunk under a block, once the biome scan has finished.
    func biome(at block: CGPoint) -> String? {
        biomes[ChunkCoordinate(x: Int(block.x.rounded(.down)) >> 4, z: Int(block.y.rounded(.down)) >> 4)]
    }

    /// The image to draw for a region: the sharpest one cached that the view needs.
    func image(for region: RegionCoordinate, fullResolution: Bool) -> CGImage? {
        fullResolution ? (tiles[region] ?? previews[region]) : (previews[region] ?? tiles[region])
    }

    /// Starts rendering the visible regions that lack the resolution the view needs, nearest to the
    /// center first. A new request replaces the previous one, so panning away cancels work that's
    /// no longer visible.
    func requestTiles(visibleIn size: CGSize, displayScale: CGFloat = 2) {
        guard size.width > 0, size.height > 0 else { return }
        lastView = (size, displayScale)
        let full = needsFullResolution(displayScale: displayScale)
        // Panning within the same block of regions at the same resolution needs nothing new; this
        // runs on every frame of a pan.
        let range = viewport.visibleRegionRange(in: size)
        guard range != lastRequest?.range || full != lastRequest?.full else { return }
        lastRequest = (range, full)
        let visible = viewport.visibleRegions(in: size)
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
    private var queue: [RegionCoordinate] = []
    private var inFlight: [RegionCoordinate: Job] = [:]
    private var nextJobID = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private func startQueued() {
        while inFlight.count < regionConcurrency, !queue.isEmpty {
            let region = queue.removeFirst()
            let renderer = renderer
            nextJobID += 1
            let id = nextJobID
            let task = Task { [weak self] in
                // Await into a local before using `region` again: Swift 6.4 release builds miscompile
                // `(region, try await …, true)` so `region` reads back as (0, 0) after the suspension
                // (fahlman/MCWorld#6 has a standalone reproduction).
                let result: Result<RegionTileRenderer.RenderedTile?, any Error>
                do {
                    let tile = try await renderer.tile(for: region)
                    result = .success(tile)
                } catch {
                    result = .failure(error)
                }
                self?.finish(region, job: id, with: result)
            }
            inFlight[region] = Job(id: id, task: task)
        }
    }

    private func finish(_ region: RegionCoordinate, job id: Int, with result: Result<RegionTileRenderer.RenderedTile?, any Error>) {
        // A job cancelled because its region left the view was already removed (and may have been
        // replaced by a newer job for the same region); its result is dropped.
        guard inFlight[region]?.id == id else { return }
        inFlight[region] = nil
        switch result {
        case .success(let tile?):
            store(tile, for: region)
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
    /// Regions the game saved since their tiles were drawn. Their old images stay on screen until
    /// the new ones are ready, so a redraw doesn't flicker.
    private var stale: Set<RegionCoordinate> = []

    /// Redraws regions whose files the game saved, and shows regions it just created.
    func regionsChanged(_ regions: Set<RegionCoordinate>) {
        for region in regions {
            let file = dimension.regionDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca")
            if FileManager.default.fileExists(atPath: file.path) { availableRegions.insert(region) } else { availableRegions.remove(region) }
            // A render that started before the save may have read the old file; start it again.
            inFlight[region]?.task.cancel()
            inFlight[region] = nil
        }
        failed.subtract(regions)
        stale.formUnion(regions.filter { tiles[$0] != nil || previews[$0] != nil })
        lastRequest = nil
        if let lastView { requestTiles(visibleIn: lastView.size, displayScale: lastView.displayScale) }
    }

    /// Regions in the view at the last request; never evicted.
    private var visibleRegions: Set<RegionCoordinate> = []
    /// Whether the last request needed full-resolution tiles. When it didn't, rendered full tiles
    /// are dropped and only previews kept: fully zoomed out, keeping both cost about 1 GB.
    private var wantsFullResolution = true

    /// Waits until every requested tile has been rendered, or loading was cancelled.
    func waitUntilIdle() async {
        while isLoading {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func store(_ tile: RegionTileRenderer.RenderedTile, for region: RegionCoordinate) {
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
    private static func regionsToEvict(from cached: Set<RegionCoordinate>, keeping limit: Int,
                                       visible: Set<RegionCoordinate>, viewport: MapViewport) -> [RegionCoordinate] {
        guard cached.count > limit else { return [] }
        let candidates = cached.subtracting(visible)
            .sorted { viewport.distanceToCenter($0) > viewport.distanceToCenter($1) }
        return Array(candidates.prefix(cached.count - limit))
    }

    /// Reads the dimension's structures, places, creatures and biome areas in the background, at
    /// a lower priority than map tiles. Each list appears as soon as it's read; the scans share
    /// one read per region through `reader`.
    func loadLayers() {
        guard layerTask == nil else { return }
        let reader = reader, dimension = dimension, scanCache = scanCache
        layerTask = Task(priority: .utility) { [weak self] in
            async let places = PlaceScanner.scan(dimension, cache: scanCache)
            async let structures = StructureScanner.scan(reader)
            async let creatures = CreatureScanner.scan(reader)
            async let biomes = BiomeScanner.scan(reader)
            let foundPlaces = await places
            guard !Task.isCancelled else { return }
            self?.places = foundPlaces
            let foundStructures = await structures
            guard !Task.isCancelled else { return }
            self?.structures = foundStructures
            let foundCreatures = await creatures
            guard !Task.isCancelled else { return }
            self?.creatures = foundCreatures
            let foundBiomes = await biomes
            guard !Task.isCancelled else { return }
            self?.biomeAreas = foundBiomes.areas
            self?.biomes = foundBiomes.biomes
        }
    }

    /// Reads the layers again after the game saved. Regions that didn't change come from the scan
    /// cache; the current lists stay until the new ones arrive.
    func reloadLayers() {
        layerTask?.cancel()
        layerTask = nil
        loadLayers()
    }

    /// Waits for the scan started by `loadLayers()`.
    func waitForLayers() async {
        await layerTask?.value
    }

    func cancel() {
        layerTask?.cancel()
        lastRequest = nil
        for job in inFlight.values { job.task.cancel() }
        inFlight = [:]
        queue = []
        updateLoadingState()
    }
}
