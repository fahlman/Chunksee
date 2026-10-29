import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// App scenarios built with the library's shared synthetic save builders.
nonisolated enum TestWorld {
    /// Exercise the app's production dimension read, not a separate per-layer scan path.
    static func index(_ reader: RegionReader) async -> DimensionContent {
        await DimensionContent.read(reader, previous: nil, change: .all)
    }

    struct ChunkSpec {
        var x: Int, z: Int
        var nbt: NBT
    }

    /// A chunk with one section (y 0–15). `index(x, y, z)` returns a palette index.
    static func chunk(x: Int, z: Int, palette: [String], index: (Int, Int, Int) -> Int) -> ChunkSpec {
        let indices = (0..<16).flatMap { y in (0..<16).flatMap { z in (0..<16).map { x in index(x, y, z) } } }
        let section = Fixtures.section(y: 0, palette: palette.map(NBT.string), indices: indices)
        return ChunkSpec(x: x, z: z, nbt: Fixtures.chunk(x: x, z: z, dataVersion: SaveVersion.java26_3,
            sections: [section], extra: ["yPos": .int(0)]))
    }

    static func make(chunks: [ChunkSpec], dimensionSettings: [String: NBT] = [:]) throws -> URL {
        let root = try Fixtures.tempDirectory()
        let regionDir = root.appendingPathComponent("dimensions/minecraft/overworld/region")
        try FileManager.default.createDirectory(at: regionDir, withIntermediateDirectories: true)
        var levelData: [String: NBT] = ["LevelName": .string("Test"), "DataVersion": .int(Int32(SaveVersion.java26_3))]
        try TestWorldResources.write(to: root)
        levelData["DataPacks"] = .compound(["Enabled": .list([.string("vanilla"), .string(TestWorldResources.pack)])])
        let level = NBT.compound(["Data": .compound(levelData)])
        try Fixtures.writeGzippedNBT(level, to: root.appendingPathComponent("level.dat"))
        if !dimensionSettings.isEmpty {
            try Fixtures.writeGzippedNBT(.compound([
                "DataVersion": .int(Int32(SaveVersion.java26_3)),
                "data": .compound(["dimensions": .compound(dimensionSettings)]),
            ]), to: root.appendingPathComponent("data/minecraft/world_gen_settings.dat"))
        }
        let dimension = try #require(try World(contentsOf: root).dimension("minecraft:overworld"))
        for (region, regionChunks) in Dictionary(grouping: chunks, by: { ChunkPosition(x: $0.x, z: $0.z).region }) {
            try Fixtures.write(regionFile(regionChunks), to: dimension.regionURL(at: region))
        }
        return root
    }

    static func noiseDimension(type: NBT, noise: NBT) -> NBT {
        .compound(["type": type, "generator": .compound(["type": .string("minecraft:noise"), "settings": noise])])
    }

    /// Real library facts for tests that control when a region read completes. The temporary
    /// world is removed before returning; the fixture never fabricates the private archive shape.
    static func facts(dimensionID: String = "minecraft:overworld", blockEntities: [NBT] = [],
                      entities: [NBT] = [], inhabitedTime: Int = 0,
                      options: RegionScanOptions = RegionReader.options()) throws -> RegionFacts {
        let root = try make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(Identifier(dimensionID))
        let folder = root.appendingPathComponent("dimensions").appendingPathComponent(id.namespace).appendingPathComponent(id.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("region"), withIntermediateDirectories: true)
        let dimension = try #require(try World(contentsOf: root).dimension(dimensionID))
        if !blockEntities.isEmpty || inhabitedTime != 0 {
            let chunk = ChunkSpec(x: 0, z: 0, nbt: .compound([
                "DataVersion": .int(Int32(SaveVersion.java26_3)), "Status": .string("minecraft:full"), "sections": .list([]),
                "block_entities": .list(blockEntities), "InhabitedTime": .long(Int64(inhabitedTime)),
            ]))
            try Data(regionFile([chunk])).write(to: dimension.regionURL(at: .init(x: 0, z: 0)))
        }
        if !entities.isEmpty {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("entities"), withIntermediateDirectories: true)
            let chunk = ChunkSpec(x: 0, z: 0, nbt: .compound(["DataVersion": .int(Int32(SaveVersion.java26_3)), "Entities": .list(entities)]))
            try Data(regionFile([chunk])).write(to: dimension.regionURL(.entities, at: .init(x: 0, z: 0)))
        }
        return try dimension.scan(region: .init(x: 0, z: 0), options: options)
    }

    /// Write the old cache format explicitly, without keeping the retired production writer.
    static func legacyCache<T: Encodable>(_ value: T, name: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let data = try PropertyListEncoder().encode(value)
        try ((data as NSData).compressed(using: .lzfse) as Data).write(to: file)
        return file
    }

    /// A region file holding chunks of one region, zlib-compressed, one record per sector run.
    static func regionFile(_ chunks: [ChunkSpec]) throws -> [UInt8] {
        try Fixtures.region(chunks.map { chunk in
            let position = ChunkPosition(x: chunk.x, z: chunk.z)
            return Fixtures.RegionChunk(localX: position.localX, localZ: position.localZ, nbt: chunk.nbt, timestamp: 0)
        })
    }
}

// Focused model tests open synthetic worlds directly; production goes through DocumentGroup's
// reader. Both paths use the real bookmark identity and settings owner, with explicit stores.
extension WorldSession {
    convenience init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
                     defaults: UserDefaults, cacheRoot: URL?,
                     readRegion: @escaping RegionReader.Read = RegionReader.scan) async throws {
        self.init(resources: try await WorldResources(snapshot: snapshot, names: names, savedSearches: savedSearches,
                                           defaults: defaults, cacheRoot: cacheRoot, readRegion: readRegion))
    }

    static func open(_ url: URL, names: PlayerNames, savedSearches: SavedSearches? = nil, defaults: UserDefaults,
                     cacheRoot: URL?) async throws -> WorldSession {
        let snapshot = try await WorldSnapshot.read(url)
        return try await WorldSession(snapshot: snapshot, names: names, savedSearches: savedSearches ?? SavedSearches(defaults: defaults),
                            defaults: defaults, cacheRoot: cacheRoot)
    }

}

extension WorldResources {
    convenience init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
                     defaults: UserDefaults, cacheRoot: URL?,
                     watchWorld: @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = WorldWatcher.init,
                     readRegion: @escaping RegionReader.Read = RegionReader.scan,
                     readGameAssets: @escaping @Sendable (MinecraftResources) async throws -> GameResourceLibrary? = { try await $0.readLibrary() },
                     maintainCache: @escaping @Sendable (URL, URL) async -> Void = WorldResources.maintainCache) async throws {
        let folder = try WorldFolders(defaults: defaults).remember(snapshot.access.url)
        let prepared = try await WorldPreparation.read(snapshot, minecraft: names.minecraft)
        self.init(prepared: prepared, names: names, savedSearches: savedSearches,
                  settings: WorldSettings(folder: folder, defaults: defaults), cacheRoot: cacheRoot,
                  watchWorld: watchWorld, readRegion: readRegion, readGameAssets: readGameAssets, maintainCache: maintainCache)
    }

    func includeDimensions(from snapshot: WorldSnapshot) async throws {
        guard !isClosed else { return }
        includeDimensions(from: try await WorldPreparation.read(snapshot, minecraft: names.minecraft))
    }
}

/// Substitutes the file-read boundary; publication and its dependent reads remain real.
final class TestGameAssets {
    var result: Result<GameResourceLibrary?, any Error>?

    func read(_ minecraft: MinecraftResources) async throws -> GameResourceLibrary? {
        if let result { return try result.get() }
        return try await minecraft.readLibrary()
    }

    func publish(_ library: GameResourceLibrary?, to resources: WorldResources) async {
        result = .success(library)
        resources.refreshGameAssets()
        await resources.waitForGameAssets()
    }
}

extension AppModel {
    func resources(for snapshot: WorldSnapshot) async throws -> WorldResources {
        try await resources(for: snapshot, folder: worldFolders.remember(snapshot.access.url))
    }
}
