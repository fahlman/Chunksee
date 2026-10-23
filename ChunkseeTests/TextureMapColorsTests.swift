import CoreGraphics
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct TextureMapColorsTests {
    @Test func newBlocksUseVisibleTopPixelsAndSavedModelTurns() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let upright = BlockState("test:log", properties: ["axis": "y"])
        let sideways = BlockState("test:log", properties: ["axis": "x"])
        let turned = BlockState("test:log", properties: ["axis": "z"])
        let states = [BlockState("test:new"), upright, sideways, turned,
            BlockState("test:log"), BlockState("test:missing"), BlockState("test:occluded")]
        let colors = try await library.mapColors(for: states)
        // South turns up at X 90°; north at X 270°. Missing states keep their slot as nil.
        #expect(colors == [MapColor(0xff0000), MapColor(0xff0000), MapColor(0xffffff),
                           MapColor(0x00ff00), nil, nil, MapColor(0x0000ff)])
        #expect(try await library.mapColors(for: states) == colors)
    }

    @Test func transparentPixelsAnimationsAndWeightedModelsHaveStableColors() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let colors = try await library.mapColors(for: ["clear", "animated", "weighted"].map { BlockState("test:" + $0) })
        #expect(colors == [MapColor(0xff0000), MapColor(0xff0000), MapColor(0x4000bf)])
    }

    @Test func constantTintsAndLockedModelsResolveWhileUnknownBiomeKeepsItsFallback() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states = [BlockState("minecraft:spruce_leaves"), BlockState("minecraft:grass_block"), BlockState("test:locked")]
        let colors = try await library.mapColors(for: states)
        #expect(colors == [MapColor(0x619961), nil, MapColor(0xffffff)])
    }

    @Test func lockedPartialFacesUseTheGameCoordinatesBeforeAveragingAndCaching() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states = ["locked_0", "locked_90", "locked_180", "locked_270", "unlocked_90",
                      "locked_north", "locked_east", "locked_inverted"].map { BlockState("test:" + $0) }
        // The UV rectangle covers one quarter of an asymmetric four-color texture. UV lock
        // moves that rectangle around the texture center, not just its four vertex indexes.
        let expected = [0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff0000, 0xffff00, 0x0000ff, 0x00ff00]
            .map { MapColor(UInt32($0)) }
        #expect(try await library.mapColors(for: states) == expected.map(Optional.some))
        #expect(library.cachedMapColors(for: states) == expected.map(Optional.some))
    }

    @Test func warmColorsPreserveOrderMissingModelsAndSourceRemoval() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states = [BlockState("test:new"), BlockState("test:missing"), BlockState("test:new")]
        #expect(library.cachedMapColors(for: states) == nil)
        let colors = try await library.mapColors(for: states)
        #expect(colors == [MapColor(0xff0000), nil, MapColor(0xff0000)])
        #expect(library.cachedMapColors(for: states) == colors)
        #expect(library.cachedMapColors(for: states + [BlockState("test:unrequested")]) == nil)
        #expect(library.cachedMapColors(for: [BlockState("test:missing")]) == [nil])
        await library.close()
        #expect(library.cachedMapColors(for: states) == nil)
        await #expect(throws: CancellationError.self) { try await library.mapColors(for: states) }
    }

    @Test func sourceRemovalCannotWriteFallbackColorsUnderThePreviousSource() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let resources = MinecraftResources(defaults: TestDefaults.make())
        let version = try #require(GameAssetVersion(name: "26.3", dataVersion: 5023))
        resources.choose(fixture.root)
        let library = try #require(await resources.library(for: version))
        #expect(try await library.mapColors(for: [BlockState("test:new")]).count == 1)
        resources.forget()
        await resources.waitUntilIdle()
        await #expect(throws: CancellationError.self) { try await library.mapColors(for: [BlockState("test:new")]) }
        resources.choose(fixture.root)
        let replacement = try #require(await resources.library(for: version))
        #expect(replacement.identity != library.identity && replacement.sourceKey == library.sourceKey)
        #expect(try await replacement.mapColors(for: [BlockState("test:new")]).count == 1)
        resources.forget()
        await resources.waitUntilIdle()
    }

    @Test func terrainCacheUsesTheSourceWhileHeightAndHoverKeepTheirOwnFacts() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["test:locked_90", "minecraft:barrier"], index: { _, y, _ in y == 15 ? 1 : 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let library = try fixture.library(), position = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        let baseline = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        var colored = baseline
        colored.gameAssets = library
        let original = try #require(try await baseline.tile(for: position))
        let image = try #require(try await colored.tile(for: position))
        let hit = try #require(try await colored.tile(for: position))
        let pixels = try ItemPictureFixture.pixels(image.full)
        #expect(pixels.color(8, 8) == [0, 255, 0, 255])
        #expect(try ItemPictureFixture.pixels(hit.full).bytes == pixels.bytes)
        #expect(try ItemPictureFixture.pixels(original.full).bytes != pixels.bytes)
        let file = try #require(try dimension.region(x: 0, z: 0))
        #expect(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0)?[0]?.y == 14)
        let regionFile = dimension.regionURL(.terrain, x: 0, z: 0)
        let fallback = try #require(TileCache.key(for: position, regionFile: regionFile))
        let source = try #require(TileCache.key(for: position, regionFile: regionFile, colorSource: library.sourceKey))
        #expect(fallback.fileName != source.fileName && cache.load(source) != nil)
        #expect(TileCache.key(for: position, regionFile: regionFile, style: .height, colorSource: library.sourceKey)
            == TileCache.key(for: position, regionFile: regionFile, style: .height))
        await library.close()
        await #expect(throws: CancellationError.self) { try await colored.tile(for: position) }
    }

    @Test func replacingTheLibraryCancelsOldMapResultsAndKeepsTheViewport() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["test:new"], index: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let gate = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, _ in
            await gate.read(renderer.gameAssets == nil ? "fallback" : "assets")
        })
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        await gate.waitForRequest("fallback")
        map.setGameAssets(try fixture.library())
        await gate.waitForRequest("assets")
        let good = try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1))
        await gate.finish("assets", with: .init(full: good, preview: good))
        await map.waitUntilIdle()
        let old = try #require(CGImage.rgba([0, 255, 0, 255], width: 1, height: 1))
        await gate.finish("fallback", with: .init(full: old, preview: old))
        await map.waitForRenders()
        #expect(map.tiles[.init(x: 0, z: 0)] === good && map.viewport.center == CGPoint(x: 8, y: 8))
        map.close()
    }

    private func fixture() throws -> ItemPictureFixture {
        var files: [String: Data] = [:]
        func json(_ path: String, _ object: Any) throws { files[path] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func block(_ id: String, _ object: Any) throws {
            let parts = id.split(separator: ":")
            try json("assets/\(parts[0])/blockstates/\(parts[1]).json", object)
        }
        for id in ["new", "clear", "animated", "occluded"] {
            try block("test:" + id, ["variants": ["": ["model": id == "new" ? "test:item/cube" : "test:block/" + id]]])
        }
        try block("test:log", ["variants": [
            "axis=y": ["model": "test:item/cube"], "axis=x": ["model": "test:item/cube", "x": 90],
            "axis=z": ["model": "test:item/cube", "x": 270]]])
        try block("test:locked", ["variants": ["": ["model": "test:item/cube", "x": 90, "uvlock": true]]])
        for direction in ["up", "north", "east", "inverted"] {
            let facing = direction == "inverted" ? "up" : direction
            let uv = direction == "inverted" ? [8, 8, 0, 0] : [0, 0, 8, 8]
            try json("assets/test/models/block/partial_\(direction).json", [
                "textures": ["skin": "test:item/quadrants"],
                "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": [
                    facing: ["texture": "#skin", "uv": uv]
                ]]]])
        }
        for turn in [0, 90, 180, 270] {
            try block("test:locked_\(turn)", ["variants": ["": ["model": "test:block/partial_up", "y": turn, "uvlock": true]]])
        }
        try block("test:unlocked_90", ["variants": ["": ["model": "test:block/partial_up", "y": 90]]])
        try block("test:locked_north", ["variants": ["": ["model": "test:block/partial_north", "x": 270, "uvlock": true]]])
        try block("test:locked_east", ["variants": ["": ["model": "test:block/partial_east", "z": 270, "uvlock": true]]])
        try block("test:locked_inverted", ["variants": ["": ["model": "test:block/partial_inverted", "y": 90, "uvlock": true]]])
        try block("test:weighted", ["variants": ["": [["model": "test:block/red", "weight": 1], ["model": "test:block/blue", "weight": 3]]]])
        func face(_ texture: String, y: Int = 16, tint: Bool = false) -> [String: Any] {
            var top: [String: Any] = ["texture": "#" + String(texture.split(separator: "/").last!)]
            if tint { top["tintindex"] = 0 }
            return ["from": [0, 0, 0], "to": [16, y, 16], "faces": ["up": top]]
        }
        let textures = Dictionary(uniqueKeysWithValues: ["red", "blue", "white", "clear", "animated"].map { ($0, "test:item/" + $0) })
        for id in ["red", "blue", "clear", "animated"] {
            try json("assets/test/models/block/\(id).json", ["textures": textures, "elements": [face("test:item/" + id)]])
        }
        try json("assets/test/models/block/occluded.json", ["textures": textures, "elements": [face("test:item/red", y: 8), face("test:item/blue")]])
        try json("assets/test/models/block/tinted.json", ["textures": textures, "elements": [face("test:item/white", tint: true)]])
        for id in ["minecraft:spruce_leaves", "minecraft:grass_block"] {
            try block(id, ["variants": ["": ["model": "test:block/tinted"]]])
        }
        let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255], clear: [UInt8] = [0, 0, 0, 0]
        files["assets/test/textures/item/clear.png"] = try ItemPictureFixture.png(red + clear + clear + clear)
        files["assets/test/textures/item/animated.png"] = try ItemPictureFixture.png(Array(repeating: red, count: 4).flatMap { $0 } + Array(repeating: blue, count: 4).flatMap { $0 }, width: 2, height: 4)
        return try ItemPictureFixture(extraFiles: files)
    }
}
