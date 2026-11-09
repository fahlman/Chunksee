import CryptoKit
import Foundation
import Testing

/// Blocking file reads stay off the main actor. Foundation enumeration itself is synchronous.
nonisolated enum MapComparisonFiles {
    struct Record: Codable, Equatable, Sendable {
        let sha256: String
        let size: UInt64
        let mode: UInt16
        let modified: Double
        let device: UInt64
        let inode: UInt64

        func matchesCopiedContent(_ other: Self) -> Bool {
            sha256 == other.sha256 && size == other.size && mode == other.mode && modified == other.modified
        }
    }

    @concurrent static func snapshot(_ root: URL) async throws -> [String: Record] {
        try snapshotFiles(root)
    }

    @concurrent static func verify(_ root: URL, expected: [String: String]) async throws {
        let actual = try snapshotFiles(root)
        try #require(!expected.isEmpty && actual.mapValues(\.sha256) == expected)
    }

    /// Opening a world legitimately updates its folder's last-used time. Report folder
    /// dates separately; the file manifest remains the unchanged-cache requirement.
    @concurrent static func directoryDates(_ root: URL) async throws -> [String: Double] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let iterator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: Array(keys)))
        var result: [String: Double] = [:]
        for url in [root] + iterator.allObjects.compactMap({ $0 as? URL }) {
            let value = try url.resourceValues(forKeys: keys)
            try #require(value.isSymbolicLink == false)
            if value.isDirectory == true {
                let name = url == root ? "." : String(url.path.dropFirst(root.path.count + 1))
                result[name] = try #require(value.contentModificationDate).timeIntervalSince1970
            }
        }
        return result
    }

    @concurrent static func copyCache(from source: URL, to destination: URL) async throws {
        let before = try snapshotFiles(source)
        try #require(!before.isEmpty && !FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.copyItem(at: source, to: destination)
        let copied = try snapshotFiles(destination)
        try #require(Set(before.keys) == Set(copied.keys))
        for (name, record) in before {
            let value = try #require(copied[name])
            try #require(record.matchesCopiedContent(value))
        }
        let unchanged = try snapshotFiles(source)
        try #require(unchanged == before)
    }

    private static func snapshotFiles(_ root: URL) throws -> [String: Record] {
        let fields: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try root.resourceValues(forKeys: fields)
        try #require(values.isDirectory == true && values.isSymbolicLink == false)
        let manager = FileManager.default
        let iterator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: Array(fields)))
        var result: [String: Record] = [:]
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: fields)
            try #require(values.isSymbolicLink == false)
            if values.isDirectory == true { continue }
            try #require(values.isRegularFile == true && url.path.hasPrefix(root.path + "/"))
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let size = try #require(attributes[.size] as? NSNumber).uint64Value
            let mode = try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
            let modified = try #require(attributes[.modificationDate] as? Date).timeIntervalSince1970
            let device = try #require(attributes[.systemNumber] as? NSNumber).uint64Value
            let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
            result[relative] = Record(sha256: try digest(url), size: size, mode: mode,
                                      modified: modified, device: device, inode: inode)
        }
        return result
    }

    private static func digest(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var value = SHA256()
        while let bytes = try stream.read(upToCount: 1024 * 1024), !bytes.isEmpty { value.update(data: bytes) }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

