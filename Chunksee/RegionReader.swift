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
nonisolated struct ChunkFormats: Codable, Sendable, Equatable {
    var readable = 0
    var legacy = 0

    /// A dimension whose saved chunks are all in the old format draws nothing at all.
    var isOnlyLegacy: Bool { legacy > 0 && readable == 0 }

    static func + (a: ChunkFormats, b: ChunkFormats) -> ChunkFormats {
        ChunkFormats(readable: a.readable + b.readable, legacy: a.legacy + b.legacy)
    }
}

/// Everything the app's scans take from one region, read in a single pass over its chunks and its
/// entities file: search contents, structures, creatures, surface and cave biomes, notable blocks and time
/// spent per chunk.
nonisolated struct RegionData: Sendable {
    var contents = SearchContents()
    var structures: [StructureMarker] = []
    var creatures: [Creature] = []
    var biomes: [ChunkPosition: String] = [:]
    var caveBiomes: [ChunkPosition: [String]] = [:]
    var blocks: [ChunkPosition: [BlockDeposit]] = [:]
    /// `InhabitedTime` per chunk, index `localZ * 32 + localX`.
    var inhabitedTimes = [Int](repeating: 0, count: 1024)
    var formats = ChunkFormats()

    /// Chunk entries none of the scans read: ticks, light and other bookkeeping.
    static let keysNotNeeded = Chunk.keysNotNeededForTerrain.subtracting(["block_entities", "structures"])

    /// Reads the region; chunks that can't be read are skipped.
    @concurrent
    static func read(_ dimension: ChunkseeKit.Dimension, region: RegionPosition) async -> RegionData {
        var data = RegionData()
        if let file = try? dimension.region(x: region.x, z: region.z) {
            for (x, z) in file.chunkCoordinates {
                guard !Task.isCancelled else { break }
                guard let nbt = try? file.chunkNBT(localX: x, localZ: z, skipping: keysNotNeeded) else { continue }
                data.contents.containers += ItemContainer.containers(inChunk: nbt)
                data.contents.signs += Sign.signs(inChunk: nbt)
                data.contents.spawners += Spawner.spawners(inChunk: nbt)
                data.inhabitedTimes[z * 32 + x] = Chunk.inhabitedTime(in: nbt) ?? 0
                let chunk: Chunk?
                do {
                    chunk = try Chunk(nbt: nbt)
                    data.formats.readable += 1
                } catch ChunkError.unsupportedLegacyFormat {
                    chunk = nil
                    data.formats.legacy += 1
                } catch {
                    chunk = nil
                }
                // Unfinished chunks can already record planned structures and a placeholder biome.
                if let chunk, chunk.isFullyGenerated, let origin = region.chunkOrigin {
                    data.structures += chunk.structureStarts.map(StructureMarker.init)
                    let coordinate = ChunkPosition(x: origin.x + x, z: origin.z + z)
                    data.biomes[coordinate] = BiomeScanner.surfaceBiome(of: chunk, in: dimension.id)
                    let caves = BiomeScanner.caveBiomes(of: chunk)
                    if !caves.isEmpty { data.caveBiomes[coordinate] = caves }
                    let deposits = BlockDeposit.deposits(in: chunk)
                    if !deposits.isEmpty { data.blocks[coordinate] = deposits }
                }
            }
        }
        let entitiesFile = dimension.regionURL(.entities, x: region.x, z: region.z)
        guard !Task.isCancelled else { return data }
        if let entities = try? RegionFile(contentsOf: entitiesFile) {
            for (x, z) in entities.chunkCoordinates {
                guard !Task.isCancelled else { break }
                guard let nbt = try? entities.chunkNBT(localX: x, localZ: z) else { continue }
                data.contents.containers += ItemContainer.containers(inEntityChunk: nbt)
                data.creatures += Creature.creatures(inEntityChunk: nbt)
            }
        }
        return data
    }
}

/// Gives each scan its part of a dimension's regions, reading every region once: from the scan
/// cache when its files haven't changed, otherwise in one pass that saves every part. Scans asking
/// for the same region at once share that pass.
actor RegionReader {
    let dimension: ChunkseeKit.Dimension
    let cache: ScanCache
    /// Reads under way, by region and the fingerprint of its files when the read started.
    private var reading: [String: Task<RegionData, Never>] = [:]
    private var isClosed = false
    private let read: @Sendable (ChunkseeKit.Dimension, RegionPosition) async -> RegionData

    init(dimension: ChunkseeKit.Dimension, cache: ScanCache,
         read: @escaping @Sendable (ChunkseeKit.Dimension, RegionPosition) async -> RegionData = RegionData.read) {
        self.dimension = dimension
        self.cache = cache
        self.read = read
    }

    /// One value per region of the dimension, read in parallel, in no particular order.
    @concurrent
    nonisolated func everyRegion<T: Sendable>(_ read: @escaping @Sendable (RegionReader, RegionPosition) async -> T)
        async -> [(region: RegionPosition, value: T)] {
        guard !Task.isCancelled, await !isClosed else { return [] }
        return await withTaskGroup(of: (RegionPosition, T).self) { group in
            for file in dimension.regionFiles() {
                guard !Task.isCancelled else { break }
                let region = RegionPosition(x: file.x, z: file.z)
                group.addTask {
                    // Await into a local before returning it with `region`: Swift 6.4 release builds
                    // can misread values captured next to an awaited call in task-group children (#6).
                    let value = await read(self, region)
                    return (region, value)
                }
            }
            var all: [(region: RegionPosition, value: T)] = []
            for await result in group { all.append(result) }
            return all
        }
    }

    func contents(_ region: RegionPosition) async -> SearchContents { await part("contents", \.contents, region) }
    func structures(_ region: RegionPosition) async -> [StructureMarker] { await part("structures", \.structures, region) }
    func creatures(_ region: RegionPosition) async -> [Creature] { await part("creatures", \.creatures, region) }
    func biomes(_ region: RegionPosition) async -> [ChunkPosition: String] { await part("biomes", \.biomes, region) }
    func caveBiomes(_ region: RegionPosition) async -> [ChunkPosition: [String]] { await part("caveBiomes", \.caveBiomes, region) }
    func blocks(_ region: RegionPosition) async -> [ChunkPosition: [BlockDeposit]] { await part("blocks", \.blocks, region) }
    func inhabitedTimes(_ region: RegionPosition) async -> [Int] { await part("inhabitedTimes", \.inhabitedTimes, region) }
    func formats(_ region: RegionPosition) async -> ChunkFormats { await part("formats", \.formats, region) }

    /// Indexing needs these parts together. A cold region uses one shared pass even when the
    /// disk cache is disabled; a warm one loads only this region's existing part entries.
    func indexData(_ region: RegionPosition) async -> RegionData {
        guard !isClosed, !Task.isCancelled else { return RegionData() }
        let fingerprint = fingerprint(region)
        if let contents: SearchContents = cache.load("contents", region: region, fingerprint: fingerprint),
           let structures: [StructureMarker] = cache.load("structures", region: region, fingerprint: fingerprint),
           let creatures: [Creature] = cache.load("creatures", region: region, fingerprint: fingerprint),
           let biomes: [ChunkPosition: String] = cache.load("biomes", region: region, fingerprint: fingerprint),
           let caves: [ChunkPosition: [String]] = cache.load("caveBiomes", region: region, fingerprint: fingerprint),
           let blocks: [ChunkPosition: [BlockDeposit]] = cache.load("blocks", region: region, fingerprint: fingerprint),
           let formats: ChunkFormats = cache.load("formats", region: region, fingerprint: fingerprint) {
            var data = RegionData()
            data.contents = contents; data.structures = structures; data.creatures = creatures
            data.biomes = biomes; data.caveBiomes = caves; data.blocks = blocks; data.formats = formats
            return data
        }
        return await data(region, fingerprint: fingerprint)
    }

    private func fingerprint(_ region: RegionPosition) -> String {
        ScanCache.fingerprint([dimension.regionURL(.terrain, x: region.x, z: region.z),
                               dimension.regionURL(.entities, x: region.x, z: region.z)])
    }

    private func part<T: Codable & Sendable>(_ kind: String, _ part: KeyPath<RegionData, T> & Sendable, _ region: RegionPosition) async -> T {
        guard !isClosed, !Task.isCancelled else { return RegionData()[keyPath: part] }
        // Taken before reading, so a region the game saves meanwhile is read again next time.
        let fingerprint = fingerprint(region)
        if let saved: T = cache.load(kind, region: region, fingerprint: fingerprint) { return saved }
        return await data(region, fingerprint: fingerprint)[keyPath: part]
    }

    private func data(_ region: RegionPosition, fingerprint: String) async -> RegionData {
        let key = "\(region.x).\(region.z).\(fingerprint)"
        if let task = reading[key] { return await task.value }
        let dimension = dimension, cache = cache, read = read
        let task = Task { await Self.readAndSave(dimension, region: region, cache: cache, fingerprint: fingerprint, read: read) }
        reading[key] = task
        let data = await task.value
        reading[key] = nil
        return data
    }

    /// Refuses queued requests and waits for the shared region reads to stop.
    func close() async {
        isClosed = true
        let tasks = Array(reading.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.value }
    }

    /// Reads a region and saves each part, off the actor so other regions' requests carry on.
    @concurrent
    private nonisolated static func readAndSave(_ dimension: ChunkseeKit.Dimension, region: RegionPosition, cache: ScanCache,
                                                fingerprint: String,
                                                read: @Sendable (ChunkseeKit.Dimension, RegionPosition) async -> RegionData) async -> RegionData {
        let data = await read(dimension, region)
        guard !Task.isCancelled else { return data }
        cache.store(data.contents, "contents", region: region, fingerprint: fingerprint)
        cache.store(data.structures, "structures", region: region, fingerprint: fingerprint)
        cache.store(data.creatures, "creatures", region: region, fingerprint: fingerprint)
        cache.store(data.biomes, "biomes", region: region, fingerprint: fingerprint)
        cache.store(data.caveBiomes, "caveBiomes", region: region, fingerprint: fingerprint)
        cache.store(data.blocks, "blocks", region: region, fingerprint: fingerprint)
        cache.store(data.formats, "formats", region: region, fingerprint: fingerprint)
        cache.store(data.inhabitedTimes, "inhabitedTimes", region: region, fingerprint: fingerprint)
        return data
    }
}
