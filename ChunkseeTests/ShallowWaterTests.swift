import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ShallowWaterTests {
    @Test func shallowWaterShowsItsFloorAndDeepWaterKeepsItsColour() async throws {
        let depths = [1, 5, 16, 32]
        let url = try waterWorld(depths: depths)
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: .init(x: 0, z: 0)))
        // Sand increasingly gives way to blue; the last two retain the previous depth shading.
        let expected: [[UInt8]] = [[182, 192, 184, 255], [150, 171, 193, 255], [47, 88, 171, 255], [35, 65, 125, 255]]
        for (x, depth) in depths.enumerated() {
            let columns = try #require(RegionTileRenderer.columns(in: file, localX: x, localZ: 0))
            let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: x, localZ: 0))
            #expect(columns.allSatisfy { $0?.waterDepth == depth && $0?.y == depth })
            #expect(columns.allSatisfy { $0?.waterFloorColor == (depth == 32 ? nil : MapColor(0xDBD3A0)) })
            #expect(blocks.allSatisfy { $0 == .init(id: "minecraft:water", y: depth, waterDepth: depth) })
            #expect(pixel(pixels, x: x * 16 + 5, z: 5) == expected[x])
        }
    }

    @Test func gapsAirAndUnreadableBlocksNeverInventAFloor() async throws {
        for lightOnly in [false, true] {
            var sections = [Fixtures.section(y: 0, palette: [.string("minecraft:sand")])]
            if lightOnly { sections.append(.compound(["Y": .int(1)])) }
            sections.append(Fixtures.section(y: 2, palette: [.string("minecraft:water")]))
            let spec = TestWorld.ChunkSpec(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
                dataVersion: SaveVersion.java26_3, sections: sections, extra: ["yPos": .int(0)]))
            let url = try TestWorld.make(chunks: [spec])
            defer { try? FileManager.default.removeItem(at: url) }
            let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
            let file = try #require(try dimension.region(x: 0, z: 0))
            let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0, cutawayY: 35))
            #expect(columns.allSatisfy { $0?.waterDepth == 4 && $0?.waterFloorColor == nil })
            let pixels = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: 35).pixels(for: .init(x: 0, z: 0)))
            #expect(pixel(pixels, x: 5, z: 5) == [66, 124, 239, 255])
        }
        let spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:sand", "minecraft:water"]) { x, y, _ in
            if y == 4 || y == 5 { return 2 }
            if y == 3, x == 0 { return 7 }
            if y == 3, x == 1 { return 0 }
            return y <= 3 ? 1 : 0
        }
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0))
        #expect(columns[0]?.waterFloorColor == nil && columns[1]?.waterFloorColor == nil)
        #expect(columns[2]?.waterFloorColor == MapColor(0xDBD3A0))
        #expect(columns.allSatisfy { $0?.waterDepth == 2 && $0?.y == 5 })
    }

    @Test func cutawaysRetainTheirWaterSurfaceAndDepthViewKeepsItsScale() async throws {
        let url = try waterWorld(depths: [5])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, cutawayY: 2))
        #expect(blocks.allSatisfy { $0 == .init(id: "minecraft:water", y: 2, waterDepth: 2) })
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: 2).pixels(for: .init(x: 0, z: 0)))
        #expect(pixel(pixels, x: 5, z: 5) == [174, 187, 187, 255])
        let depth = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: 2, style: .waterDepth).pixels(for: .init(x: 0, z: 0)))
        let color = MapStylePalette.waterColor(depth: 2)
        #expect(pixel(depth, x: 5, z: 5) == [color.red, color.green, color.blue, 255])
    }

    @Test func floorColourChangesShallowsButNeitherLandNorDeepWater() async throws {
        let worlds = try ["minecraft:sand", "minecraft:stone"].map { try waterWorld(depths: [0, 1, 32], floor: $0) }
        defer { for url in worlds { try? FileManager.default.removeItem(at: url) } }
        var images = [[UInt8]]()
        for url in worlds {
            let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
            images.append(try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: .init(x: 0, z: 0))))
        }
        #expect(pixel(images[0], x: 5, z: 5) == [219, 211, 160, 255])
        #expect(pixel(images[1], x: 5, z: 5) == [125, 125, 125, 255])
        #expect(pixel(images[0], x: 21, z: 5) != pixel(images[1], x: 21, z: 5))
        #expect(pixel(images[0], x: 37, z: 5) == pixel(images[1], x: 37, z: 5))
    }

    @Test func oldWaterTilesAreReplacedAndNewPixelsAreReused() async throws {
        let url = try waterWorld(depths: [1])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: url.appendingPathComponent("test-tiles"))
        let key = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region)))
        let old = cache.directory.appendingPathComponent("r.0.0.normal.surface.hunknown.cnone.\(key.fileSize).\(key.modified).v12.lzfse")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let stale = Data(repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        try ((stale as NSData).compressed(using: .lzfse) as Data).write(to: old)
        #expect(cache.load(key) == nil)
        let renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let first = try #require(try await renderer.tile(for: region))
        let pixels = Array(try #require(first.full.image.dataProvider?.data as Data?))
        #expect(pixel(pixels, x: 5, z: 5) == [182, 192, 184, 255])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let stored = try #require(cache.load(key))
        #expect(stored.litPixels(heightScale: nil) == pixels)
        let second = try #require(try await renderer.tile(for: region))
        #expect(second.cacheWrite == nil)
        #expect(second.full.image.dataProvider?.data as Data? == first.full.image.dataProvider?.data as Data?)
    }

    private func waterWorld(depths: [Int], floor: String = "minecraft:sand") throws -> URL {
        let chunks = depths.enumerated().map { x, depth in
            let sections = (0..<3).map { section in
                Fixtures.section(y: section, palette: [.string("minecraft:air"), .string(floor), .string("minecraft:water")],
                    indices: (0..<4096).map { index in
                        let y = section * 16 + index / 256
                        return y == 0 ? 1 : y <= depth ? 2 : 0
                    })
            }
            return TestWorld.ChunkSpec(x: x, z: 0, nbt: Fixtures.chunk(x: x, z: 0,
                dataVersion: SaveVersion.java26_3, sections: sections, extra: ["yPos": .int(0)]))
        }
        return try TestWorld.make(chunks: chunks)
    }

    private func pixel(_ pixels: [UInt8], x: Int, z: Int) -> [UInt8] {
        let start = (z * RegionTileRenderer.side + x) * 4
        return Array(pixels[start..<start + 4])
    }
}
