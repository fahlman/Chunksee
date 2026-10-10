import Foundation

/// Scan results (search contents, structures, places, creatures, biomes) kept on disk per region,
/// so reopening a world lists everything at once. Like tiles, an entry is valid only for the
/// exact files it was read from (size and modification date), so regions the game changed are
/// read again.
nonisolated struct ScanCache: Sendable {
    /// Bump whenever what a scan saves changes, invalidating old entries.
    static let version = 1

    /// `nil` reads every time and saves nothing.
    let directory: URL?

    /// Reads every time, for tests and worlds without a cache folder.
    static let off = ScanCache(directory: nil)

    /// The scans folder inside a dimension's tile folder, where tile pruning also covers it.
    init(forWorldAt world: URL, dimensionID: String) {
        directory = TileCache.directory(forWorldAt: world, dimensionID: dimensionID)?.appendingPathComponent("scans", isDirectory: true)
    }

    init(directory: URL?) {
        self.directory = directory
    }

    /// The saved `kind` result for a region, or `read()`'s result, saved for next time. `sources`
    /// are the files the result comes from; a missing file counts as a state of its own.
    func value<T: Codable>(_ kind: String, region: RegionCoordinate, sources: [URL], read: () -> T) -> T {
        guard let directory else { return read() }
        let prefix = "\(kind).\(region.x).\(region.z)."
        let file = directory.appendingPathComponent(prefix + Self.fingerprint(sources) + ".v\(Self.version)")
        if let data = try? Data(contentsOf: file), let plist = try? (data as NSData).decompressed(using: .lzfse) as Data,
           let value = try? PropertyListDecoder().decode(T.self, from: plist) {
            return value
        }
        let value = read()
        // Failing to save only costs reading the region again next time.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let plist = try? encoder.encode(value), let data = try? (plist as NSData).compressed(using: .lzfse) as Data {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
            try? data.write(to: file, options: .atomic)
        }
        return value
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
