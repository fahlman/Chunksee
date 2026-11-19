import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct ShallowWaterTests {
    @Test func textureOpacityLimitsTheFloorAndTheExistingShadeDimsIt() async throws {
        let url = try waterWorld(depths: [1, 5, 15, 32])
        let fixture = try waterFixture(alpha: 192)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), library = try fixture.library()
        let assets = try #require(try GameAssets(contentsOf: fixture.jar))
        let context = MapSurfaceContext(settings: nil, water: try WorldDefinitions.read(world, assets: assets).water)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")), surfaceContext: context)
        renderer.gameData = library.data
        renderer.gameArtwork = library
        let pixels = try #require(try await renderer.pixels(for: .init(x: 0, z: 0)))
        // Synthetic art is deliberately different from Minecraft's installed opacity.
        let expected: [[UInt8]] = [[114, 159, 236, 255], [104, 144, 217, 255], [55, 95, 174, 255], [35, 65, 125, 255]]
        for x in expected.indices {
            let actual = pixel(pixels, x: x * 16 + 5, z: 5)
            #expect(actual == expected[x])
        }
        await library.close()
    }

    @Test func missingWaterArtPreservesEveryExistingWaterPixel() async throws {
        let url = try waterWorld(depths: [1, 5, 15, 32])
        let fixture = try waterFixture(alpha: nil)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        var renderer = RegionTileRenderer(dimension: dimension)
        let fallback = try #require(try await renderer.pixels(for: .init(x: 0, z: 0)))
        let library = try fixture.library()
        renderer.gameData = library.data
        renderer.gameArtwork = library
        #expect(try await renderer.pixels(for: .init(x: 0, z: 0)) == fallback)
        #expect(try await library.waterAppearance().opacity == nil)
        await library.close()
    }

    @Test func opacityReadsTheFirstTextureFrameAndRetiresWithItsLibrary() async throws {
        let fixture = try waterFixture(alpha: 64)
        defer { fixture.remove() }
        let library = try fixture.library()
        #expect(library.cachedWaterAppearance == nil)
        let first = try await library.waterAppearance()
        #expect(first.opacity == 64.0 / 255)
        #expect(library.cachedWaterAppearance === first)
        #expect(try await library.waterAppearance() === first)
        await library.close()
        #expect(library.cachedWaterAppearance == nil)
    }

    @Test func artworkSwitchKeepsTheWaterFactsAndChangesOnlyItsPictureBlend() async throws {
        let root = try waterWorld(depths: [5]), fixture = try waterFixture(alpha: 192)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(fixture.root)
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let session = WorldSession(resources: resources), map = try #require(session.map)
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        let region = RegionPosition(x: 0, z: 0), context = (try requiredRenderer(map)).surfaceContext
        let data = try #require((try requiredRenderer(map)).gameData), reader = resources.readers["minecraft:overworld"]
        #expect(context.water != nil && context.waterKey != nil)
        let original = try #require(try await (try requiredRenderer(map)).pixels(for: region))
        #expect(pixel(original, x: 5, z: 5) == [104, 144, 217, 255])

        names.minecraft.usesGameArtwork = false
        await resources.waitForRefresh()
        #expect(try requiredRenderer(map).gameData === data && requiredRenderer(map).gameArtwork == nil)
        #expect(try requiredRenderer(map).surfaceContext == context && resources.readers["minecraft:overworld"] === reader)
        let fallback = try #require(try await (try requiredRenderer(map)).pixels(for: region))
        #expect(pixel(fallback, x: 5, z: 5) == [150, 171, 193, 255])

        names.minecraft.usesGameArtwork = true
        await resources.waitForRefresh()
        #expect(try await requiredRenderer(map).pixels(for: region) == original)
        #expect(try requiredRenderer(map).surfaceContext == context && resources.readers["minecraft:overworld"] === reader)
        session.close()
        await session.waitUntilClosed()
        names.minecraft.forget()
        await names.minecraft.waitUntilIdle()
    }

    @Test func gameFluidFactsAgreeAcrossTheSurfaceHoverAndDepthStyle() async throws {
        let states: [NBT] = [.compound(["Name": .string("minecraft:kelp")]),
            .compound(["Name": .string("minecraft:seagrass")]),
            .compound(["Name": .string("minecraft:oak_stairs"), "Properties": .compound(["waterlogged": .string("true")])]),
            .compound(["Name": .string("minecraft:tube_coral")]),
            .compound(["Name": .string("minecraft:oak_stairs"), "Properties": .compound([
                "waterlogged": .string("true"), "half": .string("top")])])]
        let chunks = states.enumerated().map { x, state in
            let palette = ["minecraft:air", "minecraft:sand", "minecraft:water"].map {
                NBT.compound(["Name": .string($0)])
            } + [state]
            let section = Fixtures.section(y: 0, palette: palette, indices: (0..<4096).map { index in
                    let y = index / 256
                    return y == 0 ? 1 : y == 3 || y == 5 ? 3 : y < 5 ? 2 : 0
                })
            return TestWorld.ChunkSpec(x: x, z: 0, nbt: Fixtures.chunk(x: x, z: 0,
                dataVersion: 5023, sections: [section], extra: ["yPos": .int(0)]))
        }
        let url = try TestWorld.make(chunks: chunks), fixture = try waterFixture(alpha: 192)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), assets = try #require(try GameAssets(contentsOf: fixture.jar))
        let context = MapSurfaceContext(settings: nil, water: try WorldDefinitions.read(world, assets: assets).water)
        let dimension = try #require(world.dimension("overworld")), file = try #require(try dimension.region(x: 0, z: 0))
        let library = try fixture.library()
        var renderer = RegionTileRenderer(dimension: dimension, surfaceContext: context)
        renderer.gameData = library.data
        renderer.gameArtwork = library
        let normal = try #require(try await renderer.pixels(for: .init(x: 0, z: 0)))
        renderer.style = .waterDepth
        let depth = try #require(try await renderer.pixels(for: .init(x: 0, z: 0)))
        for x in states.indices {
            let columns = try #require(RegionTileRenderer.columns(in: file, localX: x, localZ: 0, context: context))
            let hover = try #require(try await renderer.topBlocks(in: file, localX: x, localZ: 0))
            let expectedDepth = x == 4 ? 0 : 5
            #expect(columns.allSatisfy { $0?.waterDepth == expectedDepth && $0?.y == 5 })
            #expect(hover.allSatisfy { $0?.waterDepth == expectedDepth && $0?.y == 5 })
            if x < 4 {
                let actual = pixel(normal, x: x * 16 + 5, z: 5)
                #expect(actual == [104, 144, 217, 255])
                let color = MapStylePalette.waterColor(depth: 5)
                #expect(pixel(depth, x: x * 16 + 5, z: 5) == [color.red, color.green, color.blue, 255])
            } else {
                #expect(hover.allSatisfy { $0?.id == "minecraft:oak_stairs" })
                #expect(pixel(normal, x: x * 16 + 5, z: 5) != [104, 144, 217, 255])
            }
        }
        await library.close()
    }

    @Test func livePackWaterTagsRefreshTheMapAndItsDiskIdentityWithoutArtwork() async throws {
        let url = try waterWorld(depths: [5])
        defer { try? FileManager.default.removeItem(at: url) }
        let tagURL = url.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/fluid/water.json")
        func write(_ values: [String]) throws {
            try FileManager.default.createDirectory(at: tagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ItemPictureFixture.json(["replace": true, "values": values]).write(to: tagURL, options: .atomic)
        }
        try write(["minecraft:water", "minecraft:flowing_water"])
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        resources.refreshDelay = .zero
        let session = WorldSession(resources: resources), map = try #require(session.map)
        let dimension = try #require(resources.world.dimension("overworld")), region = RegionPosition(x: 0, z: 0)
        let original = (try requiredRenderer(map)).surfaceContext
        let key = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region), context: original))
        #expect(original.water != nil && original.waterKey != nil)
        try write([])
        resources.worldChanged([tagURL])
        await resources.waitForRefresh()
        let emptyRenderer = try requiredRenderer(map), empty = emptyRenderer.surfaceContext
        #expect(empty.water?.members.isEmpty == true && empty.waterKey != original.waterKey)
        let changed = try #require(TileCache.key(for: region, regionFile: dimension.regionURL(at: region), context: empty))
        #expect(changed != key && changed.fileName == key.fileName)
        #expect(try InterpretationKey.identity(of: changed) != InterpretationKey.identity(of: key))
        let file = try #require(try dimension.region(x: 0, z: 0))
        #expect(try await emptyRenderer.topBlocks(in: file, localX: 0, localZ: 0)?.allSatisfy { $0?.waterDepth == 0 } == true)
        try FileManager.default.removeItem(at: tagURL)
        resources.worldChanged([tagURL])
        await resources.waitForRefresh()
        let absentRenderer = try requiredRenderer(map), absent = absentRenderer.surfaceContext
        #expect(absent.water == nil && absent.waterKey == nil)
        #expect(try await absentRenderer.topBlocks(in: file, localX: 0, localZ: 0)?.allSatisfy { $0?.waterDepth == 5 } == true)
        session.close()
        await session.waitUntilClosed()
    }

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
            let blocks = try #require(try await RegionTileRenderer(dimension: dimension).topBlocks(in: file, localX: x, localZ: 0))
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
                dataVersion: 5023, sections: sections, extra: ["yPos": .int(0)]))
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
        let blocks = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: 2).topBlocks(in: file, localX: 0, localZ: 0))
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
        let file = cache.directory.appendingPathComponent(try #require(key.fileName))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let stale = Data(repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        let oldPayload = try (stale as NSData).compressed(using: .lzfse) as Data
        try oldPayload.write(to: file)
        #expect(cache.load(key) == nil)
        let renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let first = try #require(try await renderer.tile(for: region))
        let pixels = Array(try #require(first.full.image.dataProvider?.data as Data?))
        #expect(pixel(pixels, x: 5, z: 5) == [182, 192, 184, 255])
        #expect(try Data(contentsOf: file) != oldPayload)
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
                dataVersion: 5023, sections: sections, extra: ["yPos": .int(0)]))
        }
        return try TestWorld.make(chunks: chunks)
    }

    private func waterFixture(alpha: UInt8?) throws -> ItemPictureFixture {
        var files = ["data/minecraft/tags/fluid/water.json": try ItemPictureFixture.json([
            "values": ["minecraft:water", "minecraft:flowing_water"]])]
        // This pack tests opacity, not absent models. Give its floor real pixels and its
        // fluid-bearing states explicit empty geometry so they retain the water palette.
        for name in ["sand", "water", "kelp", "seagrass", "oak_stairs", "tube_coral"] {
            files["assets/minecraft/blockstates/\(name).json"] = try ItemPictureFixture.json([
                "variants": ["": ["model": "minecraft:block/" + name]]])
            files["assets/minecraft/models/block/\(name).json"] = try ItemPictureFixture.json(["elements": []])
        }
        files["assets/minecraft/models/block/sand.json"] = try ItemPictureFixture.json([
            "textures": ["top": "minecraft:block/sand"],
            "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["up": ["texture": "#top"]]]]])
        files["assets/minecraft/textures/block/sand.png"] = try ItemPictureFixture.png(
            Array(repeating: [UInt8(219), 211, 160, 255], count: 4).flatMap { $0 })
        // The upper stair must remain a visible solid surface when coverage is measured.
        files["assets/minecraft/blockstates/oak_stairs.json"] = try ItemPictureFixture.json(["variants": [
            "half=bottom": ["model": "minecraft:block/oak_stairs"],
            "half=top": ["model": "minecraft:block/oak_stairs_top"]]])
        files["assets/minecraft/models/block/oak_stairs_top.json"] = try ItemPictureFixture.json([
            "textures": ["top": "minecraft:block/sand"],
            "elements": [["from": [0, 8, 0], "to": [16, 16, 16], "faces": ["up": ["texture": "#top"]]]]])
        if let alpha {
            // The opaque second frame must not influence the first-frame opacity.
            let first: [UInt8] = [0, 0, 0, alpha], second: [UInt8] = [0, 0, 0, 255]
            let pixels = Array(repeating: first, count: 4).flatMap { $0 }
                + Array(repeating: second, count: 4).flatMap { $0 }
            files["assets/minecraft/textures/block/water_still.png"] = try ItemPictureFixture.png(pixels, width: 2, height: 4)
        }
        return try ItemPictureFixture(extraFiles: files)
    }

    private func pixel(_ pixels: [UInt8], x: Int, z: Int) -> [UInt8] {
        let start = (z * RegionTileRenderer.side + x) * 4
        return Array(pixels[start..<start + 4])
    }
}
