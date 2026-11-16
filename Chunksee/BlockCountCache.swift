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

    private struct Entry: Codable {
        let storageVersion: Int
        let identity: String
        let counts: RegionBlockCounts
    }
    private static let storageVersion = 1
    let directory: URL?

    init(world: URL, dimensionID: String, root: URL?) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("block-counts", isDirectory: true)
    }

    func load(_ key: Key) -> RegionBlockCounts? {
        guard let file = file(key), let compressed = try? Data(contentsOf: file),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.storageVersion == Self.storageVersion,
              entry.counts.dimension == key.dimension, entry.counts.region == key.region,
              Set(key.blockIDs).isSubset(of: entry.counts.blockIDs) else { return nil }
        // A broader completed read answers a narrower request. Validate its actual coverage
        // under the current terrain stamp and interpretation before reusing it.
        var storedKey = key
        storedKey.blockIDs = entry.counts.blockIDs.sorted()
        guard let identity = try? InterpretationKey.identity(of: storedKey), entry.identity == identity else { return nil }
        return entry.counts
    }

    func store(_ counts: RegionBlockCounts, key: Key) {
        guard let directory, let file = file(key), counts.dimension == key.dimension, counts.region == key.region,
              counts.blockIDs == Set(key.blockIDs), let identity = try? InterpretationKey.identity(of: key) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Entry(storageVersion: Self.storageVersion, identity: identity, counts: counts)),
              let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try compressed.write(to: file, options: .atomic)
        } catch { return }
    }

    private func file(_ key: Key) -> URL? {
        directory?.appendingPathComponent("counts.\(key.region.x).\(key.region.z).plist.lzfse")
    }
}
