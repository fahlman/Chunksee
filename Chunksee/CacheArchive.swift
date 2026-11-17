import ChunkseeKit
import Foundation

/// One disk format and layout revision for scan, tile/detail and block-count caches.
/// Payload owners validate their own facts; this owner validates storage and source identity.
nonisolated enum CacheArchive {
    static let storageVersion = 2

    struct Entry<Payload: Codable>: Codable {
        var storageVersion = CacheArchive.storageVersion
        var identity: String
        var payload: Payload

        func matches(_ key: some Encodable) -> Bool {
            storageVersion == CacheArchive.storageVersion && identity == (try? InterpretationKey.identity(of: key))
        }
    }

    static func read<Payload: Codable>(_ type: Payload.Type, from file: URL) throws -> Entry<Payload> {
        let data = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        return try PropertyListDecoder().decode(Entry<Payload>.self, from: data)
    }

    static func load<Payload: Codable>(_ key: some Encodable, from file: URL) -> Payload? {
        guard let entry = try? read(Payload.self, from: file), entry.matches(key) else { return nil }
        return entry.payload
    }

    static func write<Payload: Codable>(_ entry: Entry<Payload>, to file: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let archive = try encoder.encode(entry)
        let data = try (archive as NSData).compressed(using: .lzfse) as Data
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    static func store<Payload: Codable>(_ payload: Payload, key: some Encodable, at file: URL) {
        guard let identity = try? InterpretationKey.identity(of: key) else { return }
        try? write(Entry(identity: identity, payload: payload), to: file)
    }

    /// The world awaits this once before cache readers/writers. Any layout change belongs
    /// to this shared version, so one marker covers every payload owner's slot names.
    static func prepare(worldFolder: URL) throws {
        let manager = FileManager.default
        let marker = worldFolder.appendingPathComponent("storage-layout-\(storageVersion)")
        guard !manager.fileExists(atPath: marker.path) else { return }
        try Task.checkCancellation()
        try manager.createDirectory(at: worldFolder, withIntermediateDirectories: true)
        for old in try manager.contentsOfDirectory(at: worldFolder, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            try manager.removeItem(at: old)
        }
        try Data().write(to: marker, options: .atomic)
    }
}
