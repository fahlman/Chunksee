import ChunkseeKit
import Foundation

/// One library-owned facts envelope per region. Source files, scan choices and both owners'
/// versions determine whether the entry is usable; app presentation is derived after loading.
nonisolated struct ScanCache: Sendable {
    /// Bump for changes to the app's scan choices/transforms; Kit versions its readers separately.
    static let transformVersion = 2
    let directory: URL?
    static let off = ScanCache(directory: nil)

    struct Key: Hashable, Sendable {
        let dimension: String
        let region: RegionPosition
        let fingerprint: String
        let options: RegionScanOptions

        init(dimension: ChunkseeKit.Dimension, region: RegionPosition, options: RegionScanOptions) {
            self.dimension = dimension.id
            self.region = region
            fingerprint = ScanCache.fingerprint(ChunkseeKit.Dimension.Folder.allCases.map {
                dimension.regionURL($0, at: region)
            })
            self.options = options
        }

        func matches(_ facts: RegionFacts) -> Bool {
            facts.dimension == dimension && facts.region == region && facts.options == options
        }

        var optionsHash: String {
            // Length-prefix IDs so even unfamiliar saved names cannot alias another set.
            let ids = options.blockIDs.map { $0.sorted().map { "\($0.utf8.count):\($0)" }.joined() } ?? "all"
            return ScanCache.hash("\(options.biomeSampleY.map(String.init) ?? "surface");\(options.height.map(String.init) ?? "unknown");\(ids)")
        }
    }

    private struct Entry: Codable {
        let transformVersion: Int
        let fingerprint: String
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
        directory?.appendingPathComponent("facts.\(key.region.x).\(key.region.z).\(key.fingerprint).k\(RegionFacts.interpretationVersion).a\(Self.transformVersion).\(key.optionsHash).lzfse")
    }

    /// A stable FNV-1a hash of each source file's size and modification date.
    static func fingerprint(_ sources: [URL]) -> String {
        var text = ""
        for url in sources {
            // FileManager rather than URL resource values, which are cached on the URL and can be stale.
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = (attributes[.size] as? NSNumber)?.intValue, let modified = attributes[.modificationDate] as? Date {
                text += "\(size):\(Int64(modified.timeIntervalSince1970 * 1_000_000));"
            } else {
                text += "-;"
            }
        }
        return hash(text)
    }

    private static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return String(hash, radix: 16)
    }
}
