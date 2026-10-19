import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Builds minimal 26.x worlds on disk using ChunkseeKit's public NBT and compression API.
nonisolated enum TestWorld {
    struct ChunkSpec {
        var x: Int, z: Int
        var nbt: NBT
    }

    /// A chunk with one section (y 0–15). `index(x, y, z)` returns a palette index.
    static func chunk(x: Int, z: Int, palette: [String], index: (Int, Int, Int) -> Int) -> ChunkSpec {
        var longs = [UInt64](repeating: 0, count: 256)  // 4 bits × 4096 entries
        for y in 0..<16 { for bz in 0..<16 { for bx in 0..<16 {
            let i = y * 256 + bz * 16 + bx
            longs[i / 16] |= UInt64(index(bx, y, bz)) << UInt64((i % 16) * 4)
        } } }
        let section = NBT.compound([
            "Y": .byte(0),
            "block_states": .compound(["palette": .list(palette.map(NBT.string)),
                                       "data": .longArray(longs.map { Int64(bitPattern: $0) })]),
            "biomes": .compound(["palette": .list([.string("minecraft:plains")])]),
        ])
        return ChunkSpec(x: x, z: z, nbt: .compound([
            "DataVersion": .int(5023), "xPos": .int(Int32(x)), "zPos": .int(Int32(z)), "yPos": .int(0),
            "Status": .string("minecraft:full"), "sections": .list([section]),
        ]))
    }

    static func make(chunks: [ChunkSpec]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeTests-\(UUID().uuidString)")
        let regionDir = root.appendingPathComponent("dimensions/minecraft/overworld/region")
        try FileManager.default.createDirectory(at: regionDir, withIntermediateDirectories: true)
        let level = NBT.compound(["Data": .compound(["LevelName": .string("Test"), "DataVersion": .int(5023)])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: root.appendingPathComponent("level.dat"))
        for (region, regionChunks) in Dictionary(grouping: chunks, by: { ChunkPosition(x: $0.x, z: $0.z).region }) {
            try Data(regionFile(regionChunks)).write(to: regionDir.appendingPathComponent("r.\(region.x).\(region.z).mca"))
        }
        return root
    }

    /// Real library facts for tests that control when a region read completes. The temporary
    /// world is removed before returning; the fixture never fabricates the private archive shape.
    static func facts(dimensionID: String = "minecraft:overworld", blockEntities: [NBT] = [],
                      entities: [NBT] = [], inhabitedTime: Int = 0) throws -> RegionFacts {
        let root = try make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(Identifier(dimensionID))
        let folder = root.appendingPathComponent("dimensions").appendingPathComponent(id.namespace).appendingPathComponent(id.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("region"), withIntermediateDirectories: true)
        let dimension = try #require(try World(contentsOf: root).dimension(dimensionID))
        if !blockEntities.isEmpty || inhabitedTime != 0 {
            let chunk = ChunkSpec(x: 0, z: 0, nbt: .compound([
                "DataVersion": .int(5023), "Status": .string("minecraft:full"), "sections": .list([]),
                "block_entities": .list(blockEntities), "InhabitedTime": .long(Int64(inhabitedTime)),
            ]))
            try Data(regionFile([chunk])).write(to: dimension.regionURL(at: .init(x: 0, z: 0)))
        }
        if !entities.isEmpty {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("entities"), withIntermediateDirectories: true)
            let chunk = ChunkSpec(x: 0, z: 0, nbt: .compound(["DataVersion": .int(5023), "Entities": .list(entities)]))
            try Data(regionFile([chunk])).write(to: dimension.regionURL(.entities, at: .init(x: 0, z: 0)))
        }
        return try dimension.scan(region: .init(x: 0, z: 0), options: RegionReader.options(in: dimensionID))
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
        var file = [UInt8](repeating: 0, count: 8192)
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        for chunk in chunks {
            let payload = try Compression.deflate(chunk.nbt.serialized())
            var record = be32(payload.count + 1) + [2] + payload
            let sectors = (record.count + 4095) / 4096
            record += [UInt8](repeating: 0, count: sectors * 4096 - record.count)
            let header = 4 * ((chunk.x & 31) + (chunk.z & 31) * 32)
            file.replaceSubrange(header..<header + 4, with: be32((file.count / 4096) << 8 | sectors))
            file += record
        }
        return file
    }
}
