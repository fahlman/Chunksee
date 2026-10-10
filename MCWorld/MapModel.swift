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
    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionCoordinate>
    private(set) var isLoading = false

    private var failed: Set<RegionCoordinate> = []
    private var pending: [RegionCoordinate] = []
    private var loadTask: Task<Void, Never>?
    private let renderer: RegionTileRenderer

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
         maxTiles: Int = 200, maxPreviews: Int = 800) {
        self.dimension = dimension
        self.maxTiles = maxTiles
        self.maxPreviews = maxPreviews
        self.regionConcurrency = max(1, regionConcurrency)
        self.renderer = RegionTileRenderer(dimension: dimension, chunkConcurrency: max(1, chunkConcurrency))
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionCoordinate(x: $0.x, z: $0.z) })
    }

    /// Whether the view shows regions large enough on screen to need full-resolution tiles:
    /// more than a preview's 256 pixels, at the display's pixel density.
    func needsFullResolution(displayScale: CGFloat) -> Bool {
        viewport.scale * CGFloat(RegionCoordinate.blockSize) * displayScale > CGFloat(RegionTileRenderer.previewSide)
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
        let full = needsFullResolution(displayScale: displayScale)
        let visible = viewport.visibleRegions(in: size)
        visibleRegions = Set(visible)
        wantsFullResolution = full
        let needed = visible.filter {
            availableRegions.contains($0) && !failed.contains($0) && (full ? tiles[$0] == nil : previews[$0] == nil)
        }
        guard needed != pending else { return }
        pending = needed
        loadTask?.cancel()
        guard !needed.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        let renderer = renderer
        let width = regionConcurrency
        loadTask = Task { [weak self] in
            await withTaskGroup(of: (RegionCoordinate, RegionTileRenderer.RenderedTile?, Bool).self) { group in
                var queue = needed[...]
                func startNext() {
                    guard let region = queue.popFirst() else { return }
                    group.addTask {
                        do {
                            return (region, try await renderer.tile(for: region), true)
                        } catch {
                            return (region, nil, !(error is CancellationError))
                        }
                    }
                }
                for _ in 0..<width { startNext() }
                for await (region, tile, finished) in group {
                    guard !Task.isCancelled else { break }
                    self?.store(tile, for: region, finished: finished)
                    startNext()
                }
            }
            guard !Task.isCancelled else { return }
            self?.pending = []
            self?.isLoading = false
        }
    }

    /// Regions in the view at the last request; never evicted.
    private var visibleRegions: Set<RegionCoordinate> = []
    /// Whether the last request needed full-resolution tiles. When it didn't, rendered full tiles
    /// are dropped and only previews kept: fully zoomed out, keeping both cost about 1 GB.
    private var wantsFullResolution = true

    /// Waits until every requested tile has been rendered or the request was replaced.
    func waitUntilIdle() async {
        while isLoading, let task = loadTask {
            await task.value
        }
    }

    private func store(_ tile: RegionTileRenderer.RenderedTile?, for region: RegionCoordinate, finished: Bool) {
        guard finished else { return }
        if let tile {
            if wantsFullResolution { tiles[region] = tile.full }
            previews[region] = tile.preview
            Self.evict(from: &tiles, keeping: maxTiles, visible: visibleRegions, viewport: viewport)
            Self.evict(from: &previews, keeping: maxPreviews, visible: visibleRegions, viewport: viewport)
        } else {
            // Unreadable or empty regions aren't retried during this session.
            failed.insert(region)
        }
    }

    /// Drops the cached images farthest from the view center until `limit` remain, never a visible one.
    private static func evict(from cache: inout [RegionCoordinate: CGImage], keeping limit: Int,
                              visible: Set<RegionCoordinate>, viewport: MapViewport) {
        guard cache.count > limit else { return }
        let candidates = cache.keys.filter { !visible.contains($0) }
            .sorted { viewport.distanceToCenter($0) > viewport.distanceToCenter($1) }
        for region in candidates.prefix(cache.count - limit) { cache[region] = nil }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        pending = []
        isLoading = false
    }
}
