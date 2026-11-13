import CryptoKit
import Foundation
import Testing

/// Input verification reads copies only. Hashing is outside every drawing interval.
nonisolated enum TerrainComparisonFiles {
    struct Record: Codable, Equatable, Sendable {
        let size: UInt64
        let sha256: String

        init(size: UInt64, sha256: String) { self.size = size; self.sha256 = sha256 }

        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            size = try values.decode(UInt64.self)
            sha256 = try values.decode(String.self)
            guard values.isAtEnd else { throw Failure.manifest }
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(size)
            try values.encode(sha256)
        }
    }

    enum Failure: Error { case manifest, symbolicLink, unsupportedEntry }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func manifest(_ path: String, sha256: String) throws -> [String: Record] {
        let data = try Data(contentsOf: URL(filePath: path))
        try #require(digest(data) == sha256)
        let entries = try JSONDecoder().decode([String: Record].self, from: data)
        try #require(!entries.isEmpty)
        return entries
    }

    @concurrent static func snapshot(_ root: URL) async throws -> [String: Record] {
        try readSnapshot(root)
    }

    /// The concurrent entry keeps file reads off the main actor. The synchronous
    /// helper owns the directory iterator throughout; it never crosses an await.
    private static func readSnapshot(_ root: URL) throws -> [String: Record] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let attributes = try root.resourceValues(forKeys: keys)
        try #require(attributes.isDirectory == true && attributes.isSymbolicLink == false)
        try #require(root.standardizedFileURL.path == root.path && root.resolvingSymlinksInPath().path == root.path)
        let entries = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)))
        var result: [String: Record] = [:]
        for case let url as URL in entries {
            try Task.checkCancellation()
            let value = try url.resourceValues(forKeys: keys)
            guard value.isSymbolicLink == false else { throw Failure.symbolicLink }
            if value.isDirectory == true { continue }
            guard value.isRegularFile == true else { throw Failure.unsupportedEntry }
            try #require(url.path.hasPrefix(root.path + "/"))
            let name = String(url.path.dropFirst(root.path.count + 1))
            result[name] = Record(size: UInt64(try #require(value.fileSize)), sha256: try digest(url))
        }
        return result
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoded(value), options: [.fragmentsAllowed])
    }

    static func write(_ artifacts: [String: Data], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in artifacts.keys.sorted() {
            try #require(!name.contains("/") && name != "." && name != "..")
            try artifacts[name]!.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }
}
