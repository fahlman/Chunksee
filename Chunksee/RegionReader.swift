import ChunkseeIndex
import Foundation
import ChunkseeKit

typealias ChunkFormats = ChunkseeIndex.DimensionIndex.Formats

/// Shares the library's one region scan between index and layer requests. The cache stores the
/// library envelope; the shared index derives groups, and the app supplies labels and geometry.
actor RegionReader {
    typealias Read = @Sendable (ChunkseeKit.Dimension, RegionPosition, RegionScanOptions) async throws -> RegionFacts

    /// Exactly the immutable facts consumed by a scan and its index projection.
    nonisolated struct Inputs: Equatable, Sendable {
        let options: RegionScanOptions
        let notableBlocks: NotableBlock.Catalog
        let structureGroups: StructureGroup.Catalog

        init(options: RegionScanOptions = RegionReader.options(),
             notableBlocks: NotableBlock.Catalog = .init(tags: [:]),
             structureGroups: StructureGroup.Catalog = .init(tags: [:])) {
            self.options = options
            self.notableBlocks = notableBlocks
            self.structureGroups = structureGroups
        }

        init(dimensionID: String, definitions: WorldDefinitions) {
            let context = MapDefinitions(dimensionID: dimensionID, definitions: definitions).context
            self.init(options: RegionReader.options(context: context, definitions: definitions),
                      notableBlocks: definitions.notableBlocks, structureGroups: definitions.structureGroups)
        }
    }

    let dimension: ChunkseeKit.Dimension
    let cache: ScanCache
    nonisolated let inputs: Inputs
    private nonisolated let cacheOptions: ScanCache.Options
    nonisolated var notableBlocks: NotableBlock.Catalog { inputs.notableBlocks }
    nonisolated var structureGroups: StructureGroup.Catalog { inputs.structureGroups }
    private var reading: [ScanCache.Key: Task<RegionFacts, Error>] = [:]
    private var isClosed = false
    private let read: Read
    private let cachePreparation: Task<Void, Never>?

    init(dimension: ChunkseeKit.Dimension, cache: ScanCache,
         inputs: Inputs = .init(), cachePreparation: Task<Void, Never>? = nil,
         read: @escaping Read = RegionReader.scan) {
        self.dimension = dimension
        self.cache = cache
        self.inputs = inputs
        cacheOptions = ScanCache.Options(inputs.options)
        self.read = read
        self.cachePreparation = cachePreparation
    }

    nonisolated static func options(context: MapSurfaceContext = .unknown,
                                    definitions: WorldDefinitions = .init()) -> RegionScanOptions {
        RegionScanOptions(blockIDs: definitions.notableBlocks.blockIDs,
                          biomeSampleY: context.biomeSampleY, height: context.buildHeight)
    }

    @concurrent
    nonisolated static func scan(_ dimension: ChunkseeKit.Dimension, region: RegionPosition,
                                options: RegionScanOptions) async throws -> RegionFacts {
        try dimension.scan(region: region, options: options)
    }

    nonisolated var availableRegions: Set<RegionPosition> {
        Set(ChunkseeKit.Dimension.Folder.allCases.flatMap { dimension.regionFiles($0) }
            .map { RegionPosition(x: $0.x, z: $0.z) })
    }

    /// One value per saved terrain region, for layers such as Time Spent.
    @concurrent
    nonisolated func everyRegion<T: Sendable>(_ read: @escaping @Sendable (RegionReader, RegionPosition) async -> T)
        async -> [(region: RegionPosition, value: T)] {
        guard !Task.isCancelled, await !isClosed else { return [] }
        return await withTaskGroup(of: (RegionPosition, T).self) { group in
            for file in dimension.regionFiles() {
                guard !Task.isCancelled else { break }
                let region = RegionPosition(x: file.x, z: file.z)
                group.addTask {
                    let value = await read(self, region)
                    return (region, value)
                }
            }
            var all: [(region: RegionPosition, value: T)] = []
            for await result in group { all.append(result) }
            return all
        }
    }

    func facts(_ region: RegionPosition) async -> RegionFacts? {
        await cachePreparation?.value
        guard !isClosed, !Task.isCancelled else { return nil }
        let key = ScanCache.Key(dimension: dimension, region: region, options: cacheOptions)
        let task: Task<RegionFacts, Error>
        let ownsRead: Bool
        if let existing = reading[key] { task = existing; ownsRead = false }
        else {
            let dimension = dimension, cache = cache, read = read
            task = Task { try await Self.readAndSave(dimension, key: key, cache: cache, read: read) }
            reading[key] = task
            ownsRead = true
        }
        let value = try? await task.value
        if ownsRead { reading[key] = nil }
        guard !isClosed, !Task.isCancelled else { return nil }
        return value
    }

    /// Refuses queued requests and drains both cache reads and in-flight scans.
    func close() async {
        isClosed = true
        let tasks = Array(reading.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
    }

    @concurrent
    private nonisolated static func readAndSave(_ dimension: ChunkseeKit.Dimension, key: ScanCache.Key,
                                                cache: ScanCache, read: Read) async throws -> RegionFacts {
        try Task.checkCancellation()
        if let saved = cache.load(key) {
            try Task.checkCancellation()
            return saved
        }
        let facts = try await read(dimension, key.region, key.options.value)
        try Task.checkCancellation()
        guard key.matches(facts) else { throw CocoaError(.fileReadCorruptFile) }
        // A save during the scan must not persist mixed results as an unchanged region.
        if ScanCache.Key(dimension: dimension, region: key.region, options: key.options) == key {
            cache.store(facts, key: key)
        }
        return facts
    }
}
