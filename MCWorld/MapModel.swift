import CoreGraphics
import MCWorldKit
import Observation

/// Tiles and viewport for one dimension's top-down map.
@Observable
final class MapModel {
    let dimension: MCWorldKit.Dimension
    var viewport: MapViewport

    private(set) var tiles: [RegionCoordinate: CGImage] = [:]
    /// Regions that have a region file. Others are never requested.
    private(set) var availableRegions: Set<RegionCoordinate>
    private(set) var isLoading = false

    private var failed: Set<RegionCoordinate> = []
    private var pending: [RegionCoordinate] = []
    private var loadTask: Task<Void, Never>?
    private let renderer: RegionTileRenderer

    /// At 1 MB per tile, this keeps the cache around 200 MB.
    private static let maxCachedTiles = 200
    private static let maxConcurrentRenders = 4

    init(dimension: MCWorldKit.Dimension, center: CGPoint) {
        self.dimension = dimension
        self.renderer = RegionTileRenderer(dimension: dimension)
        self.viewport = MapViewport(center: center, scale: 1)
        self.availableRegions = Set(dimension.regionFiles().map { RegionCoordinate(x: $0.x, z: $0.z) })
    }

    /// Starts rendering the visible regions that aren't cached yet, nearest to the center first.
    /// A new request replaces the previous one, so panning away cancels work that's no longer visible.
    func requestTiles(visibleIn size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let needed = viewport.visibleRegions(in: size).filter {
            availableRegions.contains($0) && tiles[$0] == nil && !failed.contains($0)
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
        loadTask = Task { [weak self] in
            await withTaskGroup(of: (RegionCoordinate, CGImage?, Bool).self) { group in
                var queue = needed[...]
                func startNext() {
                    guard let region = queue.popFirst() else { return }
                    group.addTask {
                        do {
                            return (region, try renderer.image(for: region), true)
                        } catch {
                            return (region, nil, !(error is CancellationError))
                        }
                    }
                }
                for _ in 0..<Self.maxConcurrentRenders { startNext() }
                for await (region, image, finished) in group {
                    guard !Task.isCancelled else { break }
                    self?.store(image, for: region, finished: finished)
                    startNext()
                }
            }
            guard !Task.isCancelled else { return }
            self?.pending = []
            self?.isLoading = false
        }
    }

    private func store(_ image: CGImage?, for region: RegionCoordinate, finished: Bool) {
        guard finished else { return }
        if let image {
            tiles[region] = image
            evictDistantTiles()
        } else {
            // Unreadable or empty regions aren't retried during this session.
            failed.insert(region)
        }
    }

    private func evictDistantTiles() {
        guard tiles.count > Self.maxCachedTiles else { return }
        let byDistance = tiles.keys.sorted { viewport.distanceToCenter($0) > viewport.distanceToCenter($1) }
        for region in byDistance.prefix(tiles.count - Self.maxCachedTiles) { tiles[region] = nil }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        pending = []
        isLoading = false
    }
}
