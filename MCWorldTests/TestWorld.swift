import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI
import Testing
@testable import MCWorld

/// Builds minimal 26.x worlds on disk using MCWorldKit's public NBT and compression API.
enum TestWorld {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldTests-\(UUID().uuidString)")
        let regionDir = root.appendingPathComponent("dimensions/minecraft/overworld/region")
        try FileManager.default.createDirectory(at: regionDir, withIntermediateDirectories: true)
        let level = NBT.compound(["Data": .compound(["LevelName": .string("Test"), "DataVersion": .int(5023)])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: root.appendingPathComponent("level.dat"))
        for (region, regionChunks) in Dictionary(grouping: chunks, by: { RegionCoordinate(x: $0.x >> 5, z: $0.z >> 5) }) {
            try Data(regionFile(regionChunks)).write(to: regionDir.appendingPathComponent("r.\(region.x).\(region.z).mca"))
        }
        return root
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
