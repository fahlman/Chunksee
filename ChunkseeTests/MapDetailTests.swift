import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapDetailTests {
    @Test func chosenPicturesKeepPositionVariationTintsAndMissingResultsSeparate() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        var green = MapBlockColorRequest(state: .init("minecraft:grass_block"))
        green.tints.append(.init(index: 0, color: 0x123456))
        var red = green
        red.tints = .init()
        red.tints.append(.init(index: 0, color: 0xff0000))
        let requests = [MapBlockColorRequest(state: .init("minecraft:stone")), green, red,
                        MapBlockColorRequest(state: .init("test:unverified"))]
        var indices = [UInt16](repeating: .max, count: 256)
        var positions = [BlockPosition?](repeating: nil, count: 256)
        indices.replaceSubrange(0..<6, with: [0, 0, 0, 1, 2, 3])
        positions.replaceSubrange(0..<6, with: [
            .init(blockX: 0, blockY: 0, blockZ: 0), .init(blockX: 175, blockY: 63, blockZ: -16),
            .init(blockX: -1, blockY: 64, blockZ: -1), .init(blockX: 0, blockY: 0, blockZ: 0),
            .init(blockX: 0, blockY: 0, blockZ: 0), .init(blockX: 0, blockY: 0, blockZ: 0)])
        let first = try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        // Minecraft's verified weighted choices at these positions are first, second, third.
        #expect(first.prefix(5).map { $0?.rgb(at: .init(8, 8)) } == [0xff0000, 0x00ff00, 0x0000ff, 0x123456, 0xff0000])
        #expect(first.dropFirst(5).allSatisfy { $0 == nil })
        let warm = try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        #expect(warm.map { $0?.pixels } == first.map { $0?.pixels })
        await library.close()
        await #expect(throws: CancellationError.self) {
            try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        }
    }

    @Test func cachedTerrainHasCrispPixelsAtNegativePositionsWithoutReadingItsWorldAgain() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let region = RegionPosition(x: -1, z: -1), chunk = ChunkPosition(x: -1, z: -1)
        let cache = TileCache(directory: root.appendingPathComponent("tiles"))
        let assets = try fixture.library()
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        renderer.gameAssets = assets
        let cold = try #require(try await renderer.tile(for: region))
        let hit = try #require(try await renderer.tile(for: region))
        let surface = try #require(hit.detail)
        #expect(cold.detail?.detail == surface.detail && cold.detail?.heights == surface.heights)
        #expect(surface.heights[511 * 512 + 511] == 14)
        // This compositor receives only retained materials and heights. Removing the synthetic
        // region proves crossing the threshold cannot introduce another terrain file read.
        try FileManager.default.removeItem(at: dimension.regionURL(at: region))
        let detailed = try #require(try await MapDetailRenderer.render(chunk, surface: surface, assets: assets, heightScale: nil))
        let pixels = try ItemPictureFixture.pixels(detailed)
        #expect(pixels.color(2, 2) == [255, 0, 0, 255])
        #expect(pixels.color(14, 2) == [0, 255, 0, 255])
        #expect(pixels.color(2, 14) == [0, 0, 255, 255])
        #expect(pixels.color(14, 14) == [255, 255, 0, 255])
        let close = MapViewport(center: CGPoint(x: -8, y: -8), scale: 8)
        let size = CGSize(width: 120, height: 120)
        #expect(MapDetailRenderer.visibleChunks(in: surface, region: region, viewport: close, size: size) == [chunk])
        #expect(MapDetailRenderer.visibleChunks(in: surface, region: region,
            viewport: .init(center: close.center, scale: 4), size: size).isEmpty)
        #expect(MapDetailRenderer.visibleChunks(in: surface, region: region,
            viewport: .init(center: CGPoint(x: CGFloat.nan, y: 0), scale: 8), size: size).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func panningInsideARegionKeepsNeededWorkAndClosingRejectsLatePictures() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world(twoChunks: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library(), gate = AsyncReadGate<CGImage?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          renderDetail: { chunk, _, _, _ in await gate.read("\(chunk.x),\(chunk.z)") })
        map.setGameAssets(assets)
        map.viewport.scale = 8
        let size = CGSize(width: 64, height: 64)
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("-1,-1")
        map.viewport.center.x = -7
        map.requestTiles(visibleIn: size)
        let image = try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1))
        await gate.finish("-1,-1", with: image)
        await map.waitUntilIdle()
        #expect(map.detailImages[.init(x: -1, z: -1)] === image)
        map.viewport.center.x = -24
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("-2,-1")
        map.close()
        await gate.waitForCancellation("-2,-1")
        await gate.finish("-2,-1", with: image)
        await map.waitForRenders()
        #expect(map.detailImages.isEmpty && !map.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func aRetiredSourceCannotReplaceNewDetail() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let first = try fixture.library(), second = try fixture.library(), gate = AsyncReadGate<CGImage?>()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          renderDetail: { _, _, assets, _ in await gate.read(assets.identity.uuidString) })
        defer { map.close() }
        map.setGameAssets(first)
        map.viewport.scale = 8
        map.requestTiles(visibleIn: CGSize(width: 64, height: 64))
        await gate.waitForRequest(first.identity.uuidString)
        map.setGameAssets(second)
        await gate.waitForCancellation(first.identity.uuidString)
        await gate.waitForRequest(second.identity.uuidString)
        let old = try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1))
        let current = try #require(CGImage.rgba([0, 255, 0, 255], width: 1, height: 1))
        await gate.finish(second.identity.uuidString, with: current)
        await map.waitUntilIdle()
        await gate.finish(first.identity.uuidString, with: old)
        await map.waitForRenders()
        #expect(map.detailImages[.init(x: -1, z: -1)] === current)
    }

    @Test func zoomAndShareUseTheSameDetailWhileCutawaysReplaceIt() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8))
        defer { map.close() }
        map.setGameAssets(try fixture.library())
        let size = CGSize(width: 128, height: 128)
        map.viewport.scale = 4
        map.requestTiles(visibleIn: size)
        await map.waitUntilIdle()
        #expect(map.detailImages.isEmpty)
        // The complete region is already available; no new region request is needed.
        map.viewport.scale = 8
        map.requestTiles(visibleIn: size)
        await map.waitUntilIdle()
        #expect(map.detailImages[.init(x: -1, z: -1)] != nil)
        for scheme in [ColorScheme.light, .dark] {
            let image = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil },
                size: size, scale: 1, colorScheme: scheme, locale: .init(identifier: "en_US")))
            let pixels = try #require(ItemTexture(png: image.data))
            #expect(pixels.rgb(at: .init(1, 1)) == 0xff0000)
            #expect(pixels.rgb(at: .init(6, 1)) == 0x00ff00)
        }
        map.setBlockFilter(.init(highlightedIDs: ["minecraft:dirt"]))
        await map.waitUntilIdle()
        #expect(map.detailImages.isEmpty) // the shared highlight keeps its solid accent
        map.setBlockFilter(.init())
        await map.waitUntilIdle()
        #expect(!map.detailImages.isEmpty)
        map.setDepth(.init(y: -1, isSurface: false))
        await map.waitUntilIdle()
        #expect(map.detailImages.isEmpty)
        map.setDepth(.init())
        await map.waitUntilIdle()
        #expect(!map.detailImages.isEmpty)
        try FileManager.default.removeItem(at: dimension.regionURL(at: .init(x: -1, z: -1)))
        map.regionsChanged([.init(x: -1, z: -1)])
        await map.waitUntilIdle()
        #expect(map.detailImages.isEmpty)
        await map.waitForRenders()
    }

    private func world(twoChunks: Bool = false) throws -> URL {
        try TestWorld.make(chunks: (twoChunks ? [-2, -1] : [-1]).map { x in
            TestWorld.chunk(x: x, z: -1, palette: ["minecraft:dirt", "minecraft:air"]) { _, y, _ in y == 15 ? 1 : 0 }
        })
    }

    private func fixture() throws -> ItemPictureFixture {
        var files: [String: Data] = [:]
        func json(_ path: String, _ object: Any) throws { files[path] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        for (id, texture) in [("red", "red"), ("green", "green"), ("blue", "blue"), ("quadrants", "quadrants"), ("tinted", "white")] {
            var face: [String: Any] = ["texture": "#skin", "uv": [0, 0, 16, 16]]
            if id == "tinted" { face["tintindex"] = 0 }
            try json("assets/test/models/block/\(id).json", ["textures": ["skin": "test:item/\(texture)"],
                "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["up": face]]]])
        }
        files["assets/test/textures/item/green.png"] = try ItemPictureFixture.png(Array(repeating: [UInt8](arrayLiteral: 0, 255, 0, 255), count: 4).flatMap { $0 })
        try json("assets/minecraft/blockstates/stone.json", ["variants": ["": [
            ["model": "test:block/red", "weight": 1], ["model": "test:block/green", "weight": 3], ["model": "test:block/blue", "weight": 7]]]])
        for (id, model) in [("dirt", "quadrants"), ("grass_block", "tinted")] {
            try json("assets/minecraft/blockstates/\(id).json", ["variants": ["": ["model": "test:block/\(model)"]]])
        }
        try json("assets/test/blockstates/unverified.json", ["variants": ["": ["model": "test:block/red"]]])
        return try ItemPictureFixture(extraFiles: files)
    }
}
