import Foundation
import MCWorldKit

/// What search finds in a region: containers with their items, signs with text, named creatures.
nonisolated struct SearchContents: Codable, Sendable {
    var containers: [ItemContainer] = []
    var signs: [Sign] = []
    var namedCreatures: [Creature] = []
}

/// Everything the app's scans take from one region, read in a single pass over its chunks and its
/// entities file: search contents, structures, creatures, surface biomes and time spent per chunk.
nonisolated struct RegionData: Sendable {
    var contents = SearchContents()
    var structures: [StructureMarker] = []
    var creatures: [Creature] = []
    var biomes: [ChunkCoordinate: String] = [:]
    /// `InhabitedTime` per chunk, index `localZ * 32 + localX`.
    var inhabitedTimes = [Int](repeating: 0, count: 1024)

    /// Chunk entries none of the scans read: ticks, light and other bookkeeping.
    static let keysNotNeeded = Chunk.keysNotNeededForTerrain.subtracting(["block_entities", "structures"])

    /// Reads the region; chunks that can't be read are skipped.
    @concurrent
    static func read(_ dimension: MCWorldKit.Dimension, region: RegionCoordinate) async -> RegionData {
        var data = RegionData()
        if let file = try? dimension.region(x: region.x, z: region.z) {
            for (x, z) in file.chunkCoordinates {
                guard !Task.isCancelled else { break }
                guard let nbt = try? file.chunkNBT(localX: x, localZ: z, skipping: keysNotNeeded) else { continue }
                data.contents.containers += ItemContainer.containers(inChunk: nbt)
                data.contents.signs += Sign.signs(inChunk: nbt)
                data.structures += StructureStart.starts(inChunk: nbt).map(StructureMarker.init)
                data.inhabitedTimes[z * 32 + x] = nbt["InhabitedTime"]?.int ?? 0
                if let chunk = try? Chunk(nbt: nbt), let biome = BiomeScanner.surfaceBiome(of: chunk, in: dimension.id) {
                    data.biomes[ChunkCoordinate(x: region.x * 32 + x, z: region.z * 32 + z)] = biome
                }
            }
        }
        let entitiesFile = dimension.entitiesDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca")
        if let entities = try? RegionFile(contentsOf: entitiesFile) {
            for (x, z) in entities.chunkCoordinates {
                guard let nbt = try? entities.chunkNBT(localX: x, localZ: z) else { continue }
                data.contents.containers += ItemContainer.containers(inEntityChunk: nbt)
                let creatures = Creature.creatures(inEntityChunk: nbt)
                data.creatures += creatures
                data.contents.namedCreatures += creatures.filter { $0.customName != nil }
            }
        }
        return data
    }
}

/// Gives each scan its part of a dimension's regions, reading every region once: from the scan
/// cache when its files haven't changed, otherwise in one pass that saves every part. Scans asking
/// for the same region at once share that pass.
actor RegionReader {
    let dimension: MCWorldKit.Dimension
    let cache: ScanCache
    /// Reads under way, by region and the fingerprint of its files when the read started.
    private var reading: [String: Task<RegionData, Never>] = [:]

    init(dimension: MCWorldKit.Dimension, cache: ScanCache) {
        self.dimension = dimension
        self.cache = cache
    }

    /// One value per region of the dimension, read in parallel, in no particular order.
    @concurrent
    nonisolated func everyRegion<T: Sendable>(_ read: @escaping @Sendable (RegionReader, RegionCoordinate) async -> T)
        async -> [(region: RegionCoordinate, value: T)] {
        await withTaskGroup(of: (RegionCoordinate, T).self) { group in
            for file in dimension.regionFiles() {
                let region = RegionCoordinate(x: file.x, z: file.z)
                group.addTask {
                    // Await into a local before returning it with `region`: Swift 6.4 release builds
                    // can misread values captured next to an awaited call in task-group children (#6).
                    let value = await read(self, region)
                    return (region, value)
                }
            }
            var all: [(region: RegionCoordinate, value: T)] = []
            for await result in group { all.append(result) }
            return all
        }
    }

    func contents(_ region: RegionCoordinate) async -> SearchContents { await part("contents", \.contents, region) }
    func structures(_ region: RegionCoordinate) async -> [StructureMarker] { await part("structures", \.structures, region) }
    func creatures(_ region: RegionCoordinate) async -> [Creature] { await part("creatures", \.creatures, region) }
    func biomes(_ region: RegionCoordinate) async -> [ChunkCoordinate: String] { await part("biomes", \.biomes, region) }
    func inhabitedTimes(_ region: RegionCoordinate) async -> [Int] { await part("inhabitedTimes", \.inhabitedTimes, region) }

    private func part<T: Codable & Sendable>(_ kind: String, _ part: KeyPath<RegionData, T> & Sendable, _ region: RegionCoordinate) async -> T {
        // Taken before reading, so a region the game saves meanwhile is read again next time.
        let fingerprint = ScanCache.fingerprint([dimension.regionDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca"),
                                                 dimension.entitiesDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca")])
        if let saved: T = cache.load(kind, region: region, fingerprint: fingerprint) { return saved }
        let key = "\(region.x).\(region.z).\(fingerprint)"
        if let task = reading[key] { return await task.value[keyPath: part] }
        let dimension = dimension, cache = cache
        let task = Task { await Self.readAndSave(dimension, region: region, cache: cache, fingerprint: fingerprint) }
        reading[key] = task
        let data = await task.value
        reading[key] = nil
        return data[keyPath: part]
    }

    /// Reads a region and saves each part, off the actor so other regions' requests carry on.
    @concurrent
    private nonisolated static func readAndSave(_ dimension: MCWorldKit.Dimension, region: RegionCoordinate, cache: ScanCache,
                                                fingerprint: String) async -> RegionData {
        let data = await RegionData.read(dimension, region: region)
        guard !Task.isCancelled else { return data }
        cache.store(data.contents, "contents", region: region, fingerprint: fingerprint)
        cache.store(data.structures, "structures", region: region, fingerprint: fingerprint)
        cache.store(data.creatures, "creatures", region: region, fingerprint: fingerprint)
        cache.store(data.biomes, "biomes", region: region, fingerprint: fingerprint)
        cache.store(data.inhabitedTimes, "inhabitedTimes", region: region, fingerprint: fingerprint)
        return data
    }
}
