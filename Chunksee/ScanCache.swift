import ChunkseeKit
import Foundation

/// One library-owned facts envelope per region. Source files, scan choices and both owners'
/// versions determine whether the entry is usable; app presentation is derived after loading.
nonisolated struct ScanCache: Sendable {
    /// Bump for changes to the app's scan choices/transforms; Kit versions its readers separately.
    static let transformVersion = 2
    let directory: URL?
    static let off = ScanCache(directory: nil)

    /// One immutable scan publication. Its complete definitions are encoded once when the
    /// reader is created, rather than once for every region requested by its consumers.
    struct Options: Hashable, Sendable, Encodable {
        let value: RegionScanOptions
        private let identity: String?

        init(_ value: RegionScanOptions) {
            self.value = value
            identity = try? InterpretationKey.identity(of: value)
        }

        func encode(to encoder: any Encoder) throws {
            guard let identity else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                    debugDescription: "Scan options have no persistent identity"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(identity)
        }
    }

    struct Key: Hashable, Sendable, Encodable {
        var interpretation = RegionFacts.interpretationVersion
        var transform = ScanCache.transformVersion
        let dimension: String
        let region: RegionPosition
        let fingerprint: [CacheKey.FileStamp?]
        let options: Options

        init(dimension: ChunkseeKit.Dimension, region: RegionPosition, options: Options) {
            self.dimension = dimension.id
            self.region = region
            fingerprint = ScanCache.fingerprint(ChunkseeKit.Dimension.Folder.allCases.map {
                dimension.regionURL($0, at: region)
            })
            self.options = options
        }

        func matches(_ facts: RegionFacts) -> Bool {
            facts.dimension == dimension && facts.region == region && facts.options == options.value
        }

    }

    init(forWorldAt world: URL, dimensionID: String, root: URL?) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("scans", isDirectory: true)
    }

    init(directory: URL?) { self.directory = directory }

    func load(_ key: Key) -> RegionFacts? {
        guard let file = file(key), let facts: RegionFacts = CacheArchive.load(key, from: file),
              key.matches(facts) else { return nil }
        return facts
    }

    /// A late write for an older input may replace this slot, but its identity cannot pass a
    /// newer reader's validation. Cache failure only costs another scan.
    func store(_ facts: RegionFacts, key: Key) {
        guard key.matches(facts), let file = file(key) else { return }
        CacheArchive.store(facts, key: key, at: file)
    }

    private func file(_ key: Key) -> URL? {
        directory?.appendingPathComponent("facts.\(key.region.x).\(key.region.z).plist.lzfse")
    }

    /// Preserve source order and missing files; the complete key owns stable encoding.
    static func fingerprint(_ sources: [URL]) -> [CacheKey.FileStamp?] {
        sources.map { CacheKey.fileStamp(for: $0) }
    }
}
