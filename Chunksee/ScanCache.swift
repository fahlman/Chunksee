import Foundation

/// Scan results (search contents, structures, places, creatures, biomes, time spent) kept on disk per region,
/// so reopening a world lists everything at once. Like tiles, an entry is valid only for the
/// exact files it was read from (size and modification date), so regions the game changed are
/// read again.
nonisolated struct ScanCache: Sendable {
    /// Bump whenever what a scan saves changes, invalidating old entries.
    /// 2: one read per region fills every scan's entry (fahlman/Chunksee#53).
    /// 3: biomes only from fully generated chunks, and Sulfur Caves as a cave biome (fahlman/Chunksee#79).
    /// 4: structures only from finished chunks; explicitly unplaced and empty starts excluded.
    /// 5: spawners in search contents (fahlman/Chunksee#121).
    /// 6: saved current health on creatures (fahlman/Chunksee#145).
    /// 7: saved pet maximum health, order, appearance, collar and equipment (same issue).
    /// 8: stable creature UUIDs for player-pet links and selection through movement.
    static let version = 8

    /// `nil` reads every time and saves nothing.
    let directory: URL?

    /// Reads every time, for tests and worlds without a cache folder.
    static let off = ScanCache(directory: nil)

    /// The scans folder inside a dimension's tile folder, where tile pruning also covers it.
    init(forWorldAt world: URL, dimensionID: String, root: URL? = TileCache.root) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID, root: root)?
            .appendingPathComponent("scans", isDirectory: true)
    }

    init(directory: URL?) {
        self.directory = directory
    }

    /// The saved `kind` result for a region, or `read()`'s result, saved for next time. `sources`
    /// are the files the result comes from; a missing file counts as a state of its own.
    func value<T: Codable>(_ kind: String, region: RegionCoordinate, sources: [URL], read: () -> T) -> T {
        guard directory != nil else { return read() }
        // Taken before reading, so a file the game saves meanwhile is read again next time.
        let fingerprint = Self.fingerprint(sources)
        if let saved: T = load(kind, region: region, fingerprint: fingerprint) { return saved }
        let value = read()
        store(value, kind, region: region, fingerprint: fingerprint)
        return value
    }

    /// The saved `kind` result for a region whose source files have `fingerprint`.
    func load<T: Codable>(_ kind: String, region: RegionCoordinate, fingerprint: String) -> T? {
        guard let file = file(kind, region: region, fingerprint: fingerprint),
              let data = try? Data(contentsOf: file), let plist = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: plist)
    }

    /// Saves a result, replacing older ones for the region. Failing to save only costs reading the
    /// region again next time.
    func store<T: Codable>(_ value: T, _ kind: String, region: RegionCoordinate, fingerprint: String) {
        guard let directory, let file = file(kind, region: region, fingerprint: fingerprint) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let plist = try? encoder.encode(value), let data = try? (plist as NSData).compressed(using: .lzfse) as Data else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = Self.prefix(kind, region)
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try? data.write(to: file, options: .atomic)
    }

    private static func prefix(_ kind: String, _ region: RegionCoordinate) -> String { "\(kind).\(region.x).\(region.z)." }

    private func file(_ kind: String, region: RegionCoordinate, fingerprint: String) -> URL? {
        directory?.appendingPathComponent(Self.prefix(kind, region) + fingerprint + ".v\(Self.version)")
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
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return String(hash, radix: 16)
    }
}
