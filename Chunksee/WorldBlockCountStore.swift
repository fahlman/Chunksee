import ChunkseeIndex
import ChunkseeKit
import Foundation
import Observation

nonisolated struct BlockSearchPoint: Hashable, Sendable {
    let dimension: String
    let origin: BlockSearchOrigin
}

/// Query windows share raw counts, while their captured points control ordering independently.
nonisolated final class BlockCountSnapshot: Sendable {
    struct Stamp: Equatable, Sendable { let file: CacheKey.FileStamp? }
    let world: WorldReadSource?
    let dimensions: [String: BlockCountIndex]
    let stamps: [String: [RegionPosition: Stamp]]
    init(world: WorldReadSource? = nil, dimensions: [String: BlockCountIndex] = [:], stamps: [String: [RegionPosition: Stamp]] = [:]) {
        self.world = world
        self.dimensions = dimensions; self.stamps = stamps
    }
}

/// One lower-priority producer for the world's demanded block searches. The ordinary index
/// finishes first. Its existing work owner cancels/drains this producer when demand ends.
@Observable
final class WorldBlockCountStore {
    typealias Read = @Sendable (ChunkseeKit.Dimension, RegionPosition, Set<String>) async throws -> RegionBlockCounts
    private let loader: RefreshLoader<Source, Request, BlockCountSnapshot>
    private let index: WorldIndexStore
    private var demand: Set<BlockSearchPoint> = []
    private(set) var catalog: NotableBlock.Catalog
    private let empty = BlockCountSnapshot()
    var snapshot: BlockCountSnapshot { loader.value ?? empty }
    var isClosed: Bool { loader.isClosed || loader.work.isClosed }
    var isReading: Bool { loader.isReading }
    @ObservationIgnored private var indexObservation: ModelObservation?

    nonisolated private struct Source: Equatable, Sendable {
        let world: WorldReadSource
        let dimensions: [ChunkseeKit.Dimension]
        let cacheRoot: URL?
        let cachePreparation: Task<Void, Never>?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.world == rhs.world && lhs.dimensions.map(\.id) == rhs.dimensions.map(\.id) &&
                lhs.dimensions.map(\.url) == rhs.dimensions.map(\.url)
        }
    }

    nonisolated private struct Request: Sendable {
        let demand: Set<BlockSearchPoint>
        let blockIDs: Set<String>
    }

    init(world: WorldReadSource, dimensions: [ChunkseeKit.Dimension], catalog: NotableBlock.Catalog,
         cacheRoot: URL?, cachePreparation: Task<Void, Never>?, index: WorldIndexStore, work: BackgroundWork,
         read: @escaping Read = WorldBlockCountStore.count) {
        self.index = index
        self.catalog = catalog
        loader = RefreshLoader(progressRead: { [weak index] source, request, previous, publish in
            guard let index else { throw CancellationError() }
            await index.waitForIndex()
            await source.cachePreparation?.value
            try Task.checkCancellation()
            return .complete(try await Self.read(source, request: request, previous: previous, read: read, publish: publish))
        }, work: work, priority: .background, whenInactive: .cancel,
            source: Source(world: world, dimensions: dimensions, cacheRoot: cacheRoot, cachePreparation: cachePreparation),
            firstRequest: Request(demand: [], blockIDs: []), merge: { _, newer in newer },
            retainingValue: { value, old, new in old.world == new.world ? value : nil })
        indexObservation = ModelObservation(self, isActive: { !$0.isClosed }, read: { $0.index.snapshot }) { store, _ in
            // Reconciliation only rechecks terrain stamps. Entity/POI edits never recount.
            store.refresh()
        }
    }

    func setDemand(_ requested: Set<BlockSearchPoint>) {
        guard !isClosed, demand != requested else { return }
        demand = requested
        refresh()
    }

    func setCatalog(_ value: NotableBlock.Catalog) {
        guard !isClosed, catalog != value else { return }
        let oldIDs = catalog.blockIDs
        catalog = value
        if value.blockIDs != oldIDs { refresh() }
    }

    func replace(world: WorldReadSource, dimensions: [ChunkseeKit.Dimension], cachePreparation: Task<Void, Never>?) {
        guard !isClosed else { return }
        let source = Source(world: world, dimensions: dimensions, cacheRoot: loader.source.cacheRoot, cachePreparation: cachePreparation)
        loader.request(source: source, isEnabled: !demand.isEmpty, refresh: request)
    }

    private var request: Request { Request(demand: demand, blockIDs: catalog.blockIDs) }
    private func refresh() { loader.request(source: loader.source, isEnabled: !demand.isEmpty, refresh: request) }

    func close() { indexObservation?.cancel(); loader.close() }
    func waitForCounts() async { await loader.waitForCurrentRead() }
    func waitUntilFinished() async { await loader.waitUntilFinished() }

    @concurrent nonisolated static func count(_ dimension: ChunkseeKit.Dimension, region: RegionPosition,
                                             blockIDs: Set<String>) async throws -> RegionBlockCounts {
        try dimension.countBlocks(region: region, matching: blockIDs)
    }

    @concurrent private nonisolated static func read(_ source: Source, request: Request, previous: BlockCountSnapshot?,
                                                    read: Read,
                                                    publish: RefreshLoader<Source, Request, BlockCountSnapshot>.Progress) async throws -> BlockCountSnapshot {
        var dimensions = previous?.dimensions ?? [:], stamps = previous?.stamps ?? [:]
        let availableIDs = Set(source.dimensions.map(\.id))
        dimensions = dimensions.filter { availableIDs.contains($0.key) }
        stamps = stamps.filter { availableIDs.contains($0.key) }
        var available: [String: Set<RegionPosition>] = [:]
        var queues: [[(String, RegionPosition)]] = []
        for dimension in source.dimensions {
            let points = request.demand.filter { $0.dimension == dimension.id }.sorted {
                ($0.origin.x, $0.origin.z) < ($1.origin.x, $1.origin.z)
            }
            guard !points.isEmpty else { continue }
            try Task.checkCancellation()
            let listing = dimension.readRegionFiles(.terrain)
            guard listing.isComplete else { continue }
            let regions = Set(listing.files.map { RegionPosition(x: $0.x, z: $0.z) })
            available[dimension.id] = regions
            let currentStamps = Dictionary(uniqueKeysWithValues: regions.map {
                ($0, BlockCountSnapshot.Stamp(file: CacheKey.fileStamp(for: dimension.regionURL(.terrain, at: $0))))
            })
            var counts = dimensions[dimension.id] ?? BlockCountIndex(dimension: dimension.id)
            let changed = Set(regions.filter { stamps[dimension.id]?[$0] != currentStamps[$0] })
            counts = counts.invalidating(changed).updating(available: regions, replacements: [])
            dimensions[dimension.id] = counts
            stamps[dimension.id] = currentStamps
            for point in points {
                queues.append(counts.regionsToRead(available: regions, matching: request.blockIDs, from: point.origin).map { (dimension.id, $0) })
            }
        }
        var result = BlockCountSnapshot(world: source.world, dimensions: dimensions, stamps: stamps)
        guard await publish(result) else { throw CancellationError() }
        // Interleave each window's outward order; a distant second window does not wait for
        // the first window's whole dimension. A region is still read only once per pass.
        var scheduled: [String: Set<RegionPosition>] = [:]
        for offset in 0..<(queues.map(\.count).max() ?? 0) {
            for queue in queues where offset < queue.count {
                let (id, region) = queue[offset]
                guard scheduled[id, default: []].insert(region).inserted,
                      let dimension = source.dimensions.first(where: { $0.id == id }), let regions = available[id],
                      var counts = dimensions[id] else { continue }
                try Task.checkCancellation()
                let ids = request.blockIDs.union(counts.regions[region]?.counts?.blockIDs ?? [])
                let key = BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids)
                stamps[id, default: [:]][region] = .init(file: key.file)
                let cache = BlockCountCache(world: source.world.world.url, dimensionID: id, root: source.cacheRoot)
                do {
                    let saved: RegionBlockCounts
                    if let cached = cache.load(key) { saved = cached }
                    else {
                        saved = try await read(dimension, region, ids)
                        try Task.checkCancellation()
                        guard saved.dimension == id, saved.region == region, ids.isSubset(of: saved.blockIDs),
                              BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids) == key else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        cache.store(saved, key: key)
                    }
                    try Task.checkCancellation()
                    guard BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids) == key else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    counts = counts.updating(available: regions, replacements: [saved])
                } catch {
                    try Task.checkCancellation()
                    counts = counts.updating(available: regions, replacements: [], failed: [region])
                }
                dimensions[id] = counts
                result = BlockCountSnapshot(world: source.world, dimensions: dimensions, stamps: stamps)
                guard await publish(result) else { throw CancellationError() }
            }
        }
        return result
    }
}
