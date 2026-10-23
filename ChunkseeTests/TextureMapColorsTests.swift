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
        let states: Set<BlockState> = [BlockState("test:new"), upright, sideways, turned,
            BlockState("test:log"), BlockState("test:missing"), BlockState("test:occluded")]
        let colors = try await library.mapColors(for: states)
        #expect(colors[BlockState("test:new")] == MapColor(0xff0000))
        #expect(colors[upright] == MapColor(0xff0000))
        #expect(colors[sideways] == MapColor(0xffffff)) // The south face turns up at X 90°.
        #expect(colors[turned] == MapColor(0x00ff00)) // The north face turns up at X 270°.
        #expect(colors[BlockState("test:occluded")] == MapColor(0x0000ff))
        #expect(colors[BlockState("test:log")] == nil) // Asset JSON has no registry default.
        #expect(colors[BlockState("test:missing")] == nil)
        #expect(try await library.mapColors(for: states) == colors)
    }

    @Test func transparentPixelsAnimationsAndWeightedModelsHaveStableColors() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let colors = try await library.mapColors(for: Set(["clear", "animated", "weighted"].map { BlockState("test:" + $0) }))
        #expect(colors[BlockState("test:clear")] == MapColor(0xff0000))
        #expect(colors[BlockState("test:animated")] == MapColor(0xff0000))
        #expect(colors[BlockState("test:weighted")] == MapColor(0x4000bf))
    }

    @Test func constantTintsApplyButUnresolvedBiomeAndLockedUVsKeepFallbacks() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states: Set<BlockState> = [BlockState("minecraft:spruce_leaves"), BlockState("minecraft:grass_block"), BlockState("test:locked")]
        let colors = try await library.mapColors(for: states)
        #expect(colors[BlockState("minecraft:spruce_leaves")] == MapColor(0x619961))
        #expect(colors[BlockState("minecraft:grass_block")] == nil)
        #expect(colors[BlockState("test:locked")] == nil)
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
            palette: ["test:new", "minecraft:barrier"], index: { _, y, _ in y == 15 ? 1 : 0 })])
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
        #expect(pixels.color(8, 8) == [255, 0, 0, 255])
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
        try block("test:weighted", ["variants": ["": [["model": "test:block/red", "weight": 1], ["model": "test:block/blue", "weight": 3]]]])
        func face(_ texture: String, y: Int = 16, tint: Bool = false) -> [String: Any] {
            var top: [String: Any] = ["texture": texture]
            if tint { top["tintindex"] = 0 }
            return ["from": [0, 0, 0], "to": [16, y, 16], "faces": ["up": top]]
        }
        for id in ["red", "blue", "clear", "animated"] {
            try json("assets/test/models/block/\(id).json", ["elements": [face("test:item/" + id)]])
        }
        try json("assets/test/models/block/occluded.json", ["elements": [face("test:item/red", y: 8), face("test:item/blue")]])
        try json("assets/test/models/block/tinted.json", ["elements": [face("test:item/white", tint: true)]])
        for id in ["minecraft:spruce_leaves", "minecraft:grass_block"] {
            try block(id, ["variants": ["": ["model": "test:block/tinted"]]])
        }
        let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255], clear: [UInt8] = [0, 0, 0, 0]
        files["assets/test/textures/item/clear.png"] = try ItemPictureFixture.png(red + clear + clear + clear)
        files["assets/test/textures/item/animated.png"] = try ItemPictureFixture.png(Array(repeating: red, count: 4).flatMap { $0 } + Array(repeating: blue, count: 4).flatMap { $0 }, width: 2, height: 4)
        return try ItemPictureFixture(extraFiles: files)
    }
}
