import CoreGraphics
import Foundation
import MCWorldKit
import Testing
@testable import MCWorld

@Suite struct MapViewportTests {
    let size = CGSize(width: 800, height: 600)

    @Test func centerOfViewIsViewportCenter() {
        let viewport = MapViewport(center: CGPoint(x: 100, y: -50), scale: 2)
        #expect(viewport.blockPoint(at: CGPoint(x: 400, y: 300), in: size) == CGPoint(x: 100, y: -50))
        #expect(viewport.blockPoint(at: CGPoint(x: 0, y: 0), in: size) == CGPoint(x: -100, y: -200))
    }

    @Test func regionRectsLineUpWithBlockCoordinates() {
        let viewport = MapViewport(center: .zero, scale: 1)
        #expect(viewport.viewRect(for: RegionCoordinate(x: 0, z: 0), in: size) == CGRect(x: 400, y: 300, width: 512, height: 512))
        #expect(viewport.viewRect(for: RegionCoordinate(x: -1, z: -1), in: size) == CGRect(x: -112, y: -212, width: 512, height: 512))
    }

    @Test func visibleRegionsAreNearestFirst() {
        let viewport = MapViewport(center: CGPoint(x: 256, y: 256), scale: 1)
        let regions = viewport.visibleRegions(in: size)
        #expect(regions.first == RegionCoordinate(x: 0, z: 0))
        // The view spans blocks x -144…656 and z -44…556, which touches regions -1…1 on both axes.
        #expect(Set(regions) == Set((-1...1).flatMap { x in (-1...1).map { RegionCoordinate(x: x, z: $0) } }))
        #expect(regions.count == 9)
    }

    @Test func zoomKeepsAnchorFixedAndClamps() {
        var viewport = MapViewport(center: .zero, scale: 1)
        let anchor = CGPoint(x: 600, y: 100)
        let before = viewport.blockPoint(at: anchor, in: size)
        viewport.zoom(by: 4, anchor: anchor, in: size)
        #expect(viewport.scale == 4)
        #expect(viewport.blockPoint(at: anchor, in: size) == before)
        viewport.zoom(by: 1000, anchor: anchor, in: size)
        #expect(viewport.scale == MapViewport.scaleRange.upperBound)
    }

    @Test func dragMovesContentWithPointer() {
        var viewport = MapViewport(center: .zero, scale: 2)
        viewport.pan(by: CGSize(width: 20, height: -10))
        #expect(viewport.center == CGPoint(x: -10, y: 5))
    }
}

@Suite struct BlockColorsTests {
    @Test func airIsTransparent() {
        #expect(BlockColors.color(for: "minecraft:air") == nil)
        #expect(BlockColors.color(for: "minecraft:cave_air") == nil)
    }

    @Test func knownAndFamilyColors() {
        #expect(BlockColors.color(for: "minecraft:grass_block") == MapColor(0x7CBD6B))
        #expect(BlockColors.color(for: "minecraft:spruce_leaves") == BlockColors.color(for: "minecraft:oak_leaves"))
        #expect(BlockColors.color(for: "minecraft:light_gray_wool") != BlockColors.color(for: "minecraft:gray_wool"))
    }

    @Test func unknownBlocksGetAStableColor() {
        let first = BlockColors.color(for: "mymod:strange_block")
        #expect(first != nil)
        #expect(first == BlockColors.color(for: "mymod:strange_block"))
    }
}

@Suite struct RegionTileRendererTests {
    @Test func rendersSurfaceWaterGapsAndRelief() async throws {
        let world = try TestWorld.make(chunks: [
            // Chunk (0, 0): stone floor at y 0; grass at y 1 for x < 8, water at y 1 for x ≥ 8.
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:grass_block", "minecraft:water"]) { x, y, _ in
                y == 0 ? 1 : y == 1 ? (x < 8 ? 2 : 3) : 0
            },
            // Chunk (0, 1): solid stone up to y 2, one block higher than chunk (0, 0)'s grass.
            TestWorld.chunk(x: 0, z: 1, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= 2 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }

        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionCoordinate(x: 0, z: 0)))

        func pixel(_ x: Int, _ z: Int) -> [UInt8] { Array(pixels[((z * 512) + x) * 4 ..< ((z * 512) + x) * 4 + 4]) }
        func rgba(_ c: MapColor) -> [UInt8] { [c.red, c.green, c.blue, 255] }

        #expect(pixel(2, 5) == rgba(MapColor(0x7CBD6B)))                    // grass, level with its north neighbor
        #expect(pixel(10, 5) == rgba(MapColor(0x3F76E4).shaded(1.125)))     // water, one block deep
        #expect(pixel(20, 5)[3] == 0)                                        // chunk (1, 0) not generated
        #expect(pixel(2, 16) == rgba(MapColor(0x7D7D7D).shaded(1.12)))      // higher than the chunk to its north
        #expect(pixel(2, 17) == rgba(MapColor(0x7D7D7D)))                    // level with its north neighbor
        #expect(RegionTileRenderer.makeImage(pixels)?.width == 512)
    }

    @Test func parallelChunksMatchSequential() async throws {
        let world = try TestWorld.make(chunks: (0..<4).flatMap { x in (0..<4).map { z in
            TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone", "minecraft:grass_block", "minecraft:water"]) { bx, y, bz in
                y < (bx + bz + x * 3 + z) % 9 ? 1 : y == (bx + bz + x * 3 + z) % 9 ? (bx % 3 == 0 ? 3 : 2) : 0
            }
        } })
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionCoordinate(x: 0, z: 0)
        let sequential = try await RegionTileRenderer(dimension: dimension, chunkConcurrency: 1).pixels(for: region)
        let parallel = try await RegionTileRenderer(dimension: dimension, chunkConcurrency: 8).pixels(for: region)
        #expect(sequential != nil)
        #expect(parallel == sequential)
    }

    @Test func missingRegionFileRendersNothing() async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        #expect(try await RegionTileRenderer(dimension: dimension).pixels(for: RegionCoordinate(x: 3, z: 3)) == nil)
    }
}

@Suite struct MapModelTests {
    @Test func loadsEveryVisibleRegionThatExists() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let map = MapModel(dimension: dimension, center: .zero, regionConcurrency: 2, chunkConcurrency: 2)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600))
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(!map.isLoading)
        // Four regions are visible around the origin, but only r.0.0 exists.
        #expect(Array(map.tiles.keys) == [RegionCoordinate(x: 0, z: 0)])
    }
}

@Suite struct LevelOfDetailTests {
    func stoneWorld(regions: [RegionCoordinate]) throws -> URL {
        try TestWorld.make(chunks: regions.map { r in
            TestWorld.chunk(x: r.x * 32, z: r.z * 32, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        })
    }

    @Test func fullResolutionOnlyWhenRegionsAreLargeOnScreen() throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 0.25   // a region is 128 points: 256 pixels at 2×, the preview's size
        #expect(!map.needsFullResolution(displayScale: 2))
        map.viewport.scale = 0.5
        #expect(map.needsFullResolution(displayScale: 2))
        #expect(!map.needsFullResolution(displayScale: 1))
    }

    @Test func visibleTilesSurviveASmallCacheAndPreviewsArePrepared() async throws {
        let regions = [RegionCoordinate(x: -1, z: -1), RegionCoordinate(x: 0, z: -1), RegionCoordinate(x: -1, z: 0), RegionCoordinate(x: 0, z: 0)]
        let world = try stoneWorld(regions: regions)
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero,
                           maxTiles: 1, maxPreviews: 1)
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        // All four regions are visible, so none is evicted despite the limit of one.
        #expect(Set(map.tiles.keys) == Set(regions))
        #expect(Set(map.previews.keys) == Set(regions))
        #expect(map.previews[RegionCoordinate(x: 0, z: 0)]?.width == RegionTileRenderer.previewSide)
    }

    @Test func zoomedOutRequestsNeedOnlyPreviews() async throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: .zero)
        map.viewport.scale = 1.0 / 16
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.image(for: RegionCoordinate(x: 0, z: 0), fullResolution: false)?.width == RegionTileRenderer.previewSide)
        #expect(map.tiles.isEmpty)  // full tiles aren't kept when only previews are needed
        // A second request at the same zoom has nothing left to do.
        map.requestTiles(visibleIn: CGSize(width: 800, height: 600), displayScale: 2)
        #expect(!map.isLoading)
    }

    @Test func panningWithinLoadedRegionsRequestsNothingButNewRegionsLoad() async throws {
        let world = try stoneWorld(regions: [RegionCoordinate(x: 0, z: 0), RegionCoordinate(x: 3, z: 0)])
        defer { try? FileManager.default.removeItem(at: world) }
        let map = MapModel(dimension: try #require(try World(contentsOf: world).dimension("overworld")), center: CGPoint(x: 256, y: 256))
        let size = CGSize(width: 400, height: 300)
        map.requestTiles(visibleIn: size, displayScale: 2)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionCoordinate(x: 0, z: 0)] != nil)
        map.viewport.pan(by: CGSize(width: -10, height: 0))   // still inside region (0, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(!map.isLoading)
        map.viewport.center = CGPoint(x: 3 * 512 + 256, y: 256)  // over region (3, 0)
        map.requestTiles(visibleIn: size, displayScale: 2)
        #expect(map.isLoading)
        await map.waitUntilIdle()
        #expect(map.tiles[RegionCoordinate(x: 3, z: 0)] != nil)
    }

    @Test func halfSizeAveragesBlocksOfFour() {
        var pixels = [UInt8](repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        // Top-left 2×2 block: two opaque white pixels, two transparent.
        for i in [0, 1] { for c in 0..<4 { pixels[i * 4 + c] = 255 } }
        let half = RegionTileRenderer.halfSize(pixels)
        #expect(half.count == RegionTileRenderer.previewSide * RegionTileRenderer.previewSide * 4)
        #expect(Array(half[0..<4]) == [128, 128, 128, 128])
    }
}

@Suite struct TileCacheTests {
    @Test func secondRenderComesFromTheCacheAndChangesInvalidateIt() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldTileCache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionCoordinate(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: cacheDir))
        let regionFile = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")

        let first = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(TileCache(directory: cacheDir).load(key) != nil)
        let second = try #require(try await renderer.tile(for: region))
        #expect(second.full.dataProvider?.data as Data? == first.full.dataProvider?.data as Data?)

        // Touching the region file (as the game does on save) makes a new key; the old entry is replaced.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: regionFile.path)
        let newKey = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(newKey != key)
        #expect(TileCache(directory: cacheDir).load(newKey) == nil)
        _ = try await renderer.tile(for: region)
        #expect(TileCache(directory: cacheDir).load(newKey) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count == 1)
    }
}

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
    private static func regionFile(_ chunks: [ChunkSpec]) throws -> [UInt8] {
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
