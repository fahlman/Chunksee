import Foundation
import ChunkseeKit

/// What search reads from a region's block entities and entities: containers with their items, and
/// signs with text. Creatures come from the creature layer.
nonisolated struct SearchContents: Codable, Sendable {
    var containers: [ItemContainer] = []
    var signs: [Sign] = []
    var spawners: [Spawner] = []
}

/// How many of a region's chunks ChunkseeKit could read, and how many it rejected as saved before
/// Minecraft 1.18 (`ChunkError.unsupportedLegacyFormat`).
nonisolated struct ChunkFormats: Sendable, Equatable {
    var readable = 0
    var legacy = 0

    /// A dimension whose saved chunks are all in the old format draws nothing at all.
    var isOnlyLegacy: Bool { legacy > 0 && readable == 0 }

    static func + (a: ChunkFormats, b: ChunkFormats) -> ChunkFormats {
        ChunkFormats(readable: a.readable + b.readable, legacy: a.legacy + b.legacy)
    }
}

/// Shares the library's one region scan between index and layer requests. The cache stores the
/// library envelope; grouping, labels and map geometry are derived by the app afterwards.
actor RegionReader {
    typealias Read = @Sendable (ChunkseeKit.Dimension, RegionPosition) async throws -> RegionFacts

    let dimension: ChunkseeKit.Dimension
    let cache: ScanCache
    private var reading: [ScanCache.Key: Task<RegionFacts, Error>] = [:]
    private var isClosed = false
    private let read: Read

    init(dimension: ChunkseeKit.Dimension, cache: ScanCache, read: @escaping Read = RegionReader.scan) {
        self.dimension = dimension
        self.cache = cache
        self.read = read
    }

    nonisolated static func options(in dimension: String) -> RegionScanOptions {
        RegionScanOptions(blockIDs: Set(NotableBlock.byID.keys),
                          biomeSampleY: dimension == "minecraft:the_nether" ? 64 : nil)
    }

    @concurrent
    nonisolated static func scan(_ dimension: ChunkseeKit.Dimension, region: RegionPosition) async throws -> RegionFacts {
        try dimension.scan(region: region, options: options(in: dimension.id))
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
        guard !isClosed, !Task.isCancelled else { return nil }
        let key = ScanCache.Key(dimension: dimension, region: region, options: Self.options(in: dimension.id))
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

    func contents(_ region: RegionPosition) async -> SearchContents {
        guard let facts = await facts(region) else { return SearchContents() }
        return facts.searchContents
    }
    func structures(_ region: RegionPosition) async -> [StructureMarker] { await facts(region)?.structures.map(StructureMarker.init) ?? [] }
    func creatures(_ region: RegionPosition) async -> [Creature] { await facts(region)?.creatures ?? [] }
    func biomes(_ region: RegionPosition) async -> [ChunkPosition: String] { await facts(region)?.surfaceBiomes ?? [:] }
    func caveBiomes(_ region: RegionPosition) async -> [ChunkPosition: [String]] { await facts(region)?.caveBiomes ?? [:] }
    func inhabitedTimes(_ region: RegionPosition) async -> [Int] { await facts(region)?.inhabitedTimes ?? [] }

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
        let facts = try await read(dimension, key.region)
        try Task.checkCancellation()
        guard key.matches(facts) else { throw CocoaError(.fileReadCorruptFile) }
        // A save during the scan must not persist mixed results as an unchanged region.
        if ScanCache.Key(dimension: dimension, region: key.region, options: key.options) == key {
            cache.store(facts, key: key)
        }
        return facts
    }
}

extension RegionFacts {
    nonisolated var searchContents: SearchContents {
        SearchContents(containers: containers, signs: signs, spawners: spawners)
    }

    nonisolated var surfaceBiomes: [ChunkPosition: String] {
        Dictionary(uniqueKeysWithValues: chunks.compactMap { chunk in
            chunk.sampledBiome.map { (chunk.position, $0) }
        })
    }

    nonisolated var caveBiomes: [ChunkPosition: [String]] {
        Dictionary(uniqueKeysWithValues: chunks.compactMap { chunk in
            let caves = chunk.biomes.filter { BiomeScanner.caveBiomeIDs.contains($0) }
            return caves.isEmpty ? nil : (chunk.position, caves)
        })
    }
}
