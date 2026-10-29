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
        let transformVersion: Int
        let fingerprint: [CacheKey.FileStamp?]
        let facts: RegionFacts
    }

    init(forWorldAt world: URL, dimensionID: String, root: URL?) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("scans", isDirectory: true)
    }

    init(directory: URL?) { self.directory = directory }

    func load(_ key: Key) -> RegionFacts? {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let archive = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let entry = try? decoder.decode(Entry.self, from: archive),
              entry.transformVersion == Self.transformVersion, entry.fingerprint == key.fingerprint,
              key.matches(entry.facts) else { return nil }
        return entry.facts
    }

    /// Cache failure only costs another scan. Retire older envelopes and per-part entries after
    /// the new complete envelope has been written successfully.
    func store(_ facts: RegionFacts, key: Key) {
        guard key.matches(facts), let directory, let file = file(key) else { return }
        // Binary-plist decoding of the many typed chunk integers dominated the measured
        // cached reads on Xcode 27.1. Keep the same facts, using Foundation's JSON codec.
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let entry = Entry(transformVersion: Self.transformVersion, fingerprint: key.fingerprint, facts: facts)
        guard let archive = try? encoder.encode(entry), let data = try? (archive as NSData).compressed(using: .lzfse) as Data else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { return }
        let kinds = ["facts", "contents", "structures", "creatures", "biomes", "caveBiomes", "blocks", "formats", "inhabitedTimes", "places"]
        let prefixes = kinds.map { "\($0).\(key.region.x).\(key.region.z)." }
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            where name != file.lastPathComponent && prefixes.contains(where: { name.hasPrefix($0) }) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func file(_ key: Key) -> URL? {
        guard let identity = try? InterpretationKey.identity(of: key) else { return nil }
        return directory?.appendingPathComponent("facts.\(key.region.x).\(key.region.z).\(identity).lzfse")
    }

    /// Preserve source order and missing files; the complete key owns stable encoding.
    static func fingerprint(_ sources: [URL]) -> [CacheKey.FileStamp?] {
        sources.map { CacheKey.fileStamp(for: $0) }
    }
}
