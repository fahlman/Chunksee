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

    private struct Entry: Codable {
        let storageVersion: Int
        let identity: String
        let facts: RegionFacts
    }

    private static let storageVersion = 1

    init(forWorldAt world: URL, dimensionID: String, root: URL?) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("scans", isDirectory: true)
    }

    init(directory: URL?) { self.directory = directory }

    func load(_ key: Key) -> RegionFacts? {
        guard let identity = try? InterpretationKey.identity(of: key),
              let file = file(key), let data = try? Data(contentsOf: file),
              let archive = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let entry = try? PropertyListDecoder().decode(Entry.self, from: archive),
              entry.storageVersion == Self.storageVersion, entry.identity == identity,
              key.matches(entry.facts) else { return nil }
        return entry.facts
    }

    /// A late write for an older input may replace this slot, but its identity cannot pass a
    /// newer reader's validation. Cache failure only costs another scan.
    func store(_ facts: RegionFacts, key: Key) {
        guard key.matches(facts), let directory, let file = file(key),
              let identity = try? InterpretationKey.identity(of: key) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let entry = Entry(storageVersion: Self.storageVersion, identity: identity, facts: facts)
        guard let archive = try? encoder.encode(entry), let data = try? (archive as NSData).compressed(using: .lzfse) as Data else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { return }
    }

    private func file(_ key: Key) -> URL? {
        directory?.appendingPathComponent("facts.\(key.region.x).\(key.region.z).plist.lzfse")
    }

    /// Preserve source order and missing files; the complete key owns stable encoding.
    static func fingerprint(_ sources: [URL]) -> [CacheKey.FileStamp?] {
        sources.map { CacheKey.fileStamp(for: $0) }
    }
}
