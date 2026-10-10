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
    /// Every structure in the dimension's generated chunks, once the background scan finishes.
    private(set) var structures: [StructureMarker] = []
    private var structureTask: Task<Void, Never>?
    /// Every point of interest (portals, bells, beds…), once the background scan finishes.
    private(set) var places: [PlaceMarker] = []
    private(set) var creatures: [CreatureMarker] = []
    private(set) var biomeAreas: [BiomeArea] = []
    private var biomes: [ChunkCoordinate: String] = [:]
    private var placeTask: Task<Void, Never>?
    private var creatureTask: Task<Void, Never>?
    private var biomeTask: Task<Void, Never>?

    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionCoordinate>
    private(set) var isLoading = false

    private var failed: Set<RegionCoordinate> = []
    private let renderer: RegionTileRenderer
    /// Structures, places, creatures and biome areas saved between launches.
    private let scanCache: ScanCache

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
         maxTiles: Int = 200, maxPreviews: Int = 800, cacheDirectory: URL? = nil) {
        self.dimension = dimension
        self.maxTiles = maxTiles
        self.maxPreviews = maxPreviews
        self.regionConcurrency = max(1, regionConcurrency)
        self.renderer = RegionTileRenderer(dimension: dimension, chunkConcurrency: max(1, chunkConcurrency),
                                           cache: cacheDirectory.map(TileCache.init(directory:)))
        self.scanCache = ScanCache(directory: cacheDirectory?.appendingPathComponent("scans", isDirectory: true))
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionCoordinate(x: $0.x, z: $0.z) })
    }

    /// Whether the view shows regions large enough on screen to need full-resolution tiles:
    /// more than a preview's 256 pixels, at the display's pixel density.
    func needsFullResolution(displayScale: CGFloat) -> Bool {
        viewport.scale * CGFloat(RegionCoordinate.blockSize) * displayScale > CGFloat(RegionTileRenderer.previewSide)
    }

    /// The image to draw for a region: the sharpest one cached that the view needs.
    /// The surface biome of the chunk under a block, once the biome scan has finished.
    func biome(at block: CGPoint) -> String? {
        biomes[ChunkCoordinate(x: Int(block.x.rounded(.down)) >> 4, z: Int(block.y.rounded(.down)) >> 4)]
    }

    func image(for region: RegionCoordinate, fullResolution: Bool) -> CGImage? {
        fullResolution ? (tiles[region] ?? previews[region]) : (previews[region] ?? tiles[region])
    }

    /// Starts rendering the visible regions that lack the resolution the view needs, nearest to the
    /// center first. A new request replaces the previous one, so panning away cancels work that's
    /// no longer visible.
    func requestTiles(visibleIn size: CGSize, displayScale: CGFloat = 2) {
        guard size.width > 0, size.height > 0 else { return }
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
            availableRegions.contains($0) && !failed.contains($0) && (full ? tiles[$0] == nil : previews[$0] == nil)
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
        if wantsFullResolution { tiles[region] = tile.full }
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

    /// Reads the dimension's structures in the background, at a lower priority than map tiles.
    func loadStructures() {
        guard structureTask == nil else { return }
        let dimension = dimension, scanCache = scanCache
        structureTask = Task(priority: .utility) { [weak self] in
            let found = await StructureScanner.scan(dimension, cache: scanCache)
            guard !Task.isCancelled else { return }
            self?.structures = found
        }
    }

    /// Reads the dimension's named creatures, pets and villagers in the background.
    func loadCreatures() {
        guard creatureTask == nil else { return }
        let dimension = dimension, scanCache = scanCache
        creatureTask = Task(priority: .utility) { [weak self] in
            let found = await CreatureScanner.scan(dimension, cache: scanCache)
            guard !Task.isCancelled else { return }
            self?.creatures = found
        }
    }

    /// Waits for the scan started by `loadCreatures()`.
    func waitForCreatures() async {
        await creatureTask?.value
    }

    /// Finds the dimension's biome areas in the background. It reads every chunk (3.4 s for Ryan's
    /// Realm's Overworld); background priority, rather than utility, slowed it to over a minute.
    func loadBiomeAreas() {
        guard biomeTask == nil else { return }
        let dimension = dimension, scanCache = scanCache
        biomeTask = Task(priority: .utility) { [weak self] in
            let found = await BiomeScanner.scan(dimension, cache: scanCache)
            guard !Task.isCancelled else { return }
            self?.biomeAreas = found.areas
            self?.biomes = found.biomes
        }
    }

    /// Waits for the scan started by `loadBiomeAreas()`.
    func waitForBiomeAreas() async {
        await biomeTask?.value
    }

    /// Reads the dimension's points of interest in the background.
    func loadPlaces() {
        guard placeTask == nil else { return }
        let dimension = dimension, scanCache = scanCache
        placeTask = Task(priority: .utility) { [weak self] in
            let found = await PlaceScanner.scan(dimension, cache: scanCache)
            guard !Task.isCancelled else { return }
            self?.places = found
        }
    }

    /// Waits for the scan started by `loadPlaces()`.
    func waitForPlaces() async {
        await placeTask?.value
    }

    /// Waits for the structure scan started by `loadStructures()`.
    func waitForStructures() async {
        await structureTask?.value
    }

    func cancel() {
        structureTask?.cancel()
        placeTask?.cancel()
        creatureTask?.cancel()
        biomeTask?.cancel()
        lastRequest = nil
        for job in inFlight.values { job.task.cancel() }
        inFlight = [:]
        queue = []
        updateLoadingState()
    }
}
