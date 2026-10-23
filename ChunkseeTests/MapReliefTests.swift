import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapReliefTests {
    private let gray = MapColor(0xC8C8C8)

    @Test(arguments: [true, false]) func stepsAndCliffsHaveDifferentBoundedContrast(north: Bool) {
        var values: [Int: UInt8] = [:]
        for difference in [-30, -1, 0, 1, 30] {
            var surface = RegionTileRenderer.Canvas()
            surface.set(x: 1, z: 1, column: column(y: 0))
            surface.set(x: 1, z: 0, column: column(y: north ? -difference : 0))
            surface.set(x: 0, z: 1, column: column(y: north ? 0 : -difference))
            values[difference] = pixel(surface.litPixels(heightScale: nil), x: 1, z: 1)[0]
            #expect(pixel(surface.pixels, x: 1, z: 1) == [200, 200, 200, 255])
        }
        #expect(values[-30] == 150 && values[-1] == 195)
        #expect(values[0] == 200)
        #expect(values[1] == 205 && values[30] == 240)
    }

    @Test(arguments: [-1, 1]) func linearSlopesKeepTheSameShadeAcrossBothRegionEdges(direction: Int) {
        for (originX, originZ) in [(0, 0), (512, 0), (0, 512)] {
            var surface = RegionTileRenderer.Canvas()
            for z in 0..<512 {
                for x in 0..<512 {
                    surface.set(x: x, z: z, column: column(y: direction * (originX + x + originZ + z)))
                }
            }
            let lit = surface.litPixels(heightScale: nil)
            let expected: UInt8 = direction == 1 ? 210 : 190
            for (x, z) in [(0, 0), (511, 0), (0, 511), (511, 511), (16, 16), (256, 256)] {
                #expect(pixel(lit, x: x, z: z) == [expected, expected, expected, 255])
            }
        }
    }

    @Test func missingNeighboursDoNotInventSlopesAndWaterKeepsItsDepthShade() throws {
        var surface = RegionTileRenderer.Canvas()
        surface.set(x: 2, z: 2, column: column(y: 319, water: 12))
        surface.set(x: 2, z: 1, column: column(y: -64))
        surface.set(x: 1, z: 2, column: column(y: -64))
        surface.set(x: 10, z: 10, column: column(y: 40))
        let lit = surface.litPixels(heightScale: try scale(sea: 40))
        #expect(pixel(lit, x: 2, z: 2) == pixel(surface.pixels, x: 2, z: 2))
        #expect(pixel(lit, x: 10, z: 10) == [200, 200, 200, 255])
        #expect(pixel(lit, x: 11, z: 10) == [0, 0, 0, 0])
    }

    @Test func elevationUsesTheSavedSeaLevelAndTheSharedBuildScale() throws {
        var surface = RegionTileRenderer.Canvas()
        for (x, y) in [(0, -64), (4, -12), (8, 40), (12, 319)] {
            surface.set(x: x, z: 4, column: column(y: y))
        }
        let lit = surface.litPixels(heightScale: try scale(sea: 40))
        #expect(pixel(lit, x: 0, z: 4) == [184, 184, 184, 255])
        #expect(pixel(lit, x: 4, z: 4) == [196, 196, 196, 255])
        #expect(pixel(lit, x: 8, z: 4) == [200, 200, 200, 255])
        #expect(pixel(lit, x: 12, z: 4) == [184, 184, 184, 255])
        let shifted = surface.litPixels(heightScale: try scale(sea: -12))
        #expect(pixel(shifted, x: 4, z: 4) == [200, 200, 200, 255])
        #expect(pixel(shifted, x: 8, z: 4)[0] < 200)
        #expect(surface.litPixels(heightScale: nil) == surface.pixels)
        #expect(surface.litPixels(heightScale: try scale(sea: nil)) == surface.pixels)
    }

    @Test func outsideSeaLevelsAndExtremeStoredHeightsStayBounded() throws {
        for sea in [-200, -64, 319, 500] {
            let lighting = MapRelief(heightScale: try scale(sea: sea))
            for y in [Int32.min + 1, -64, 0, 319, Int32.max] {
                let value = lighting.factor(height: y, north: 0, west: 0)
                #expect(value.isFinite && (0.92...1).contains(value))
            }
        }
        var surface = RegionTileRenderer.Canvas()
        surface.set(x: 1, z: 1, column: column(y: Int(Int32.max)))
        surface.set(x: 1, z: 0, column: column(y: Int(Int32.min) + 1))
        surface.set(x: 0, z: 1, column: column(y: Int(Int32.min) + 1))
        #expect(pixel(surface.litPixels(heightScale: nil), x: 1, z: 1) == [240, 240, 240, 255])
        for y in [Int.min, Int.max, Int(Int32.min)] {
            surface.set(x: 5, z: 5, column: column(y: y))
            #expect(pixel(surface.pixels, x: 5, z: 5) == [0, 0, 0, 0])
        }
    }

    @Test func cachedSurfacesKeepUnlitColoursSignedHeightsAndWater() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReliefCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = TileCache(directory: url), key = TileCache.Key(region: .init(x: -1, z: 2), fileSize: 12, modified: 0)
        var surface = RegionTileRenderer.Canvas()
        surface.set(x: 0, z: 0, column: column(y: -64))
        surface.set(x: 1, z: 0, column: column(y: 30, water: 4))
        surface.set(x: 2, z: 0, column: column(y: Int(Int32.max)))
        cache.store(surface, for: key)
        let loaded = try #require(cache.load(key))
        #expect(loaded.pixels == surface.pixels && loaded.heights == surface.heights && loaded.isWater == surface.isWater)
        #expect(loaded.litPixels(heightScale: nil) == surface.litPixels(heightScale: nil))

        // The prior pixel-only payload must not be accepted under the new format, even if renamed.
        let file = url.appendingPathComponent(key.fileName)
        try ((Data(surface.pixels) as NSData).compressed(using: .lzfse) as Data).write(to: file)
        #expect(cache.load(key) == nil)
        cache.store(surface, for: key)
        var bytes = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        bytes[512 * 512 * 8] = 2 // Invalid water mask.
        try ((bytes as NSData).compressed(using: .lzfse) as Data).write(to: file)
        #expect(cache.load(key) == nil)
    }

    @Test func aCacheHitRelightsWithoutDecodingTheRegionOrChangingTheSavedColours() async throws {
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld")), region = RegionPosition(x: 0, z: 0)
        let file = dimension.regionURL(at: region), date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        let key = try #require(TileCache.key(for: region, regionFile: file))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, heightScale: try scale(sea: 0))
        let first = try #require(try await renderer.tile(for: region))
        await (try #require(first.cacheWrite)).store()
        let original = try #require(first.full.dataProvider?.data as Data?)
        #expect(Array(original.prefix(4)) == [125, 125, 125, 255])
        #expect(try await renderer.pixels(for: region) == Array(original))
        let cacheFile = cache.directory.appendingPathComponent(key.fileName), cachedBytes = try Data(contentsOf: cacheFile)

        // Keep the cache key, but make the fixture region empty: rereading chunks would erase the tile.
        try Data(repeating: 0, count: key.fileSize).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(TileCache.key(for: region, regionFile: file) == key)
        renderer.heightScale = try scale(sea: 319)
        let relit = try #require(try await renderer.tile(for: region))
        let changed = try #require(relit.full.dataProvider?.data as Data?)
        #expect(relit.cacheWrite == nil && changed != original)
        #expect(changed[0] > 0 && changed[0] < original[0] && changed[3] == 255)
        #expect(try Data(contentsOf: cacheFile) == cachedBytes)
        renderer.heightScale = nil
        let restored = try #require(try await renderer.tile(for: region))
        #expect(restored.full.dataProvider?.data as Data? == original)
    }

    private func column(y: Int, water: Int = 0) -> RegionTileRenderer.Column {
        .init(y: y, color: gray, waterDepth: water, section: 0, palette: 0)
    }

    private func pixel(_ pixels: [UInt8], x: Int, z: Int) -> [UInt8] {
        let i = (z * 512 + x) * 4
        return Array(pixels[i..<i + 4])
    }

    private func scale(sea: Int?) throws -> MapHeightScale {
        var noise: [String: NBT] = ["noise": .compound(["min_y": .int(-64), "height": .int(384)])]
        if let sea { noise["sea_level"] = .int(Int32(sea)) }
        let url = try TestWorld.make(chunks: [], dimensionSettings: ["minecraft:overworld":
            TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .compound(noise))])
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(MapHeightScale(settings: WorldDetails.read(try World(contentsOf: url)).dimensionSettings["minecraft:overworld"]))
    }
}
