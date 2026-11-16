import ChunkseeKit
import Foundation

/// Raw counts have a terrain-only source. Tags and search origins never invalidate them.
nonisolated struct BlockCountCache: Sendable {
    struct Key: Encodable, Equatable, Sendable {
        var interpretation = RegionBlockCounts.interpretationVersion
        let dimension: String
        let region: RegionPosition
        let file: CacheKey.FileStamp?
        var blockIDs: [String]

        init(dimension: ChunkseeKit.Dimension, region: RegionPosition, blockIDs: Set<String>) {
            self.dimension = dimension.id
            self.region = region
            file = CacheKey.fileStamp(for: dimension.regionURL(.terrain, at: region))
            self.blockIDs = blockIDs.sorted()
        }
    }

    let directory: URL?

    init(world: URL, dimensionID: String, root: URL?) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("block-counts", isDirectory: true)
    }

    func load(_ key: Key) -> RegionBlockCounts? {
        guard let file = file(key), let entry = try? CacheArchive.read(RegionBlockCounts.self, from: file),
              entry.payload.dimension == key.dimension, entry.payload.region == key.region,
              Set(key.blockIDs).isSubset(of: entry.payload.blockIDs) else { return nil }
        // A broader completed read answers a narrower request. Validate its actual coverage
        // under the current terrain stamp and interpretation before reusing it.
        var storedKey = key
        storedKey.blockIDs = entry.payload.blockIDs.sorted()
        guard entry.matches(storedKey) else { return nil }
        return entry.payload
    }

    func store(_ counts: RegionBlockCounts, key: Key) {
        guard let file = file(key), counts.dimension == key.dimension, counts.region == key.region,
              counts.blockIDs == Set(key.blockIDs) else { return }
        CacheArchive.store(counts, key: key, at: file)
    }

    private func file(_ key: Key) -> URL? {
        directory?.appendingPathComponent("counts.\(key.region.x).\(key.region.z).plist.lzfse")
    }
}
