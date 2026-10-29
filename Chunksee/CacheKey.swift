import Foundation

/// Shared disk-key primitives; each cache still owns its entry format and version.
nonisolated enum CacheKey {
    struct FileStamp: Hashable, Sendable, Codable {
        let size: Int
        let modified: Int64
    }

    static func fileStamp(for url: URL) -> FileStamp? {
        // URL resource values can be cached, so ask FileManager for the current attributes.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: Int64(modified.timeIntervalSince1970 * 1_000_000))
    }

    /// Stable FNV-1a preserves the existing on-disk keys across launches and app versions.
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return String(hash, radix: 16)
    }
}
