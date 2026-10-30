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
                        MapBlockColorRequest(state: .init("test:custom"))]
        var indices = [UInt16](repeating: .max, count: 256)
        var positions = [BlockPosition?](repeating: nil, count: 256)
        indices.replaceSubrange(0..<6, with: [0, 0, 0, 1, 2, 3])
        positions.replaceSubrange(0..<6, with: [
            .init(blockX: 0, blockY: 0, blockZ: 0), .init(blockX: 175, blockY: 63, blockZ: -16),
            .init(blockX: -1, blockY: 64, blockZ: -1), .init(blockX: 0, blockY: 0, blockZ: 0),
            .init(blockX: 0, blockY: 0, blockZ: 0), .init(blockX: 0, blockY: 0, blockZ: 0)])
        let first = try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        // Minecraft's verified weighted choices at these positions are first, second, third.
        #expect(first.prefix(6).map { $0?.rgb(at: .init(8, 8)) } == [0xff0000, 0x00ff00, 0x0000ff, 0x123456, 0xff0000, 0xff0000])
        #expect(first.dropFirst(6).allSatisfy { $0 == nil })
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
        renderer.gameData = assets.data; renderer.gameArtwork = assets
        let cold = try #require(try await renderer.tile(for: region))
        let hit = try #require(try await renderer.tile(for: region))
        #expect(hit.detail == nil) // ordinary cache hits never decode or retain close-up materials
        let surface = try #require(try await renderer.detail(for: region)).surface
        #expect(cold.detail?.detail == surface.detail && cold.detail?.heights == surface.heights)
        #expect(surface.heights[511 * 512 + 511] == 14)
        // This compositor receives only retained materials and heights. Removing the synthetic
        // region proves crossing the threshold cannot introduce another terrain file read.
        try FileManager.default.removeItem(at: dimension.regionURL(at: region))
        let detailed = try #require(try await MapDetailRenderer.render(chunk, surface: surface, assets: assets, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detailed.image)
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

    @Test(.timeLimit(.minutes(1))) func ordinaryZoomSkipsDetailReadsAndLateLoadsCannotReturnAfterZoomOutOrClose() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let gate = AsyncReadGate<RegionTileRenderer.DetailSurface?>(), numbers = ReadNumbers()
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          cacheDirectory: root.appendingPathComponent("tiles"),
                          readDetail: { _, _ in await gate.read(String(await numbers.next())) })
        defer { map.close() }
        let artwork = try fixture.library()
        gameResources.value = MapGameResources(data: artwork.data, artwork: artwork, biomeColors: nil)
        let size = CGSize(width: 64, height: 64)
        map.viewport.scale = 4
        map.requestTiles(visibleIn: size)
        await map.waitUntilIdle()
        await map.waitForRenders()
        #expect(await gate.requested.isEmpty)
        #expect(map.detailImages.isEmpty)
        let surface = try #require(try await (try requiredRenderer(map)).detail(for: .init(x: -1, z: -1)))

        map.viewport.scale = 8
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("0")
        map.viewport.scale = 4
        map.requestTiles(visibleIn: size)
        await gate.waitForCancellation("0")
        await gate.finish("0", with: surface)
        await map.waitForRenders()
        #expect(map.detailImages.isEmpty && !map.isLoading)

        map.viewport.scale = 8
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("1")
        await gate.finish("1", with: surface)
        await map.waitUntilIdle()
        #expect(!map.detailImages.isEmpty)
        map.viewport.scale = 4
        map.requestTiles(visibleIn: size)
        #expect(map.detailImages.isEmpty)
        map.viewport.scale = 8
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("2")
        map.close()
        await gate.waitForCancellation("2")
        await gate.finish("2", with: surface)
        await map.waitForRenders()
        #expect(map.detailImages.isEmpty && !map.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func panningInsideARegionKeepsNeededWorkAndClosingRejectsLatePictures() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world(twoChunks: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library(), gate = AsyncReadGate<MapTileImage?>()
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          renderDetail: { chunk, _, _, _, _ in await gate.read("\(chunk.x),\(chunk.z)") })
        gameResources.value = MapGameResources(data: assets.data, artwork: assets, biomeColors: nil)
        map.viewport.scale = 8
        let size = CGSize(width: 64, height: 64)
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("-1,-1")
        map.viewport.center.x = -7
        map.requestTiles(visibleIn: size)
        let image = try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1))
        await gate.finish("-1,-1", with: MapTileImage(image))
        await map.waitUntilIdle()
        #expect(map.detailImages[.init(x: -1, z: -1)]?.image === image)
        map.viewport.center.x = -24
        map.requestTiles(visibleIn: size)
        await gate.waitForRequest("-2,-1")
        map.close()
        await gate.waitForCancellation("-2,-1")
        await gate.finish("-2,-1", with: MapTileImage(image))
        await map.waitForRenders()
        #expect(map.detailImages.isEmpty && !map.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func aRetiredSourceCannotReplaceNewDetail() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let first = try fixture.library(), second = try fixture.library(), gate = AsyncReadGate<MapTileImage?>()
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          renderDetail: { _, _, assets, _, _ in await gate.read(assets.identity.uuidString) })
        defer { map.close() }
        gameResources.value = MapGameResources(data: first.data, artwork: first, biomeColors: nil)
        map.viewport.scale = 8
        map.requestTiles(visibleIn: CGSize(width: 64, height: 64))
        await gate.waitForRequest(first.identity.uuidString)
        gameResources.value = MapGameResources(data: second.data, artwork: second, biomeColors: nil)
        await gate.waitForCancellation(first.identity.uuidString)
        await gate.waitForRequest(second.identity.uuidString)
        let old = try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1))
        let current = try #require(CGImage.rgba([0, 255, 0, 255], width: 1, height: 1))
        await gate.finish(second.identity.uuidString, with: MapTileImage(current))
        await map.waitUntilIdle()
        await gate.finish(first.identity.uuidString, with: MapTileImage(old))
        await map.waitForRenders()
        #expect(map.detailImages[.init(x: -1, z: -1)]?.image === current)
    }

    @Test func zoomAndShareUseTheSameDetailWhileCutawaysReplaceIt() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8))
        defer { map.close() }
        let artwork = try fixture.library()
        gameResources.value = MapGameResources(data: artwork.data, artwork: artwork, biomeColors: nil)
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
            let image = try #require(MapImage.render(map, content: MapContent(gameNames: .unavailable), portalStatus: { _ in nil },
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

    @Test func closeUpKeepsNighttimePatternsAndTheSameSlopeNormalsAsOrdinaryTerrain() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library(), region = RegionPosition(x: -1, z: -1), chunk = ChunkPosition(x: -1, z: -1)
        var renderer = RegionTileRenderer(dimension: dimension)
        renderer.gameData = assets.data; renderer.gameArtwork = assets
        let tile = try #require(try await renderer.tile(for: region))
        let retained = try #require(tile.detail)
        var surface = RegionTileRenderer.Canvas(heights: retained.heights, detail: retained.detail)
        for z in 496..<512 { for x in 496..<512 { surface.heights[z * 512 + x] = Int32(x - 496) } }
        for status in [DarkSpots.Status.bright, .dark, .unknown] {
            surface.nightLight = Array(repeating: status.rawValue, count: 512 * 512)
            let detail = try #require(try await MapDetailRenderer.render(chunk, surface: surface.detailSurface,
                assets: assets, heightScale: nil, usesSavedLighting: true))
            let normals = try #require(detail.normals)
            #expect(normals.width == 16 && normals.height == 16)
            let bytes = try #require(normals.dataProvider?.data as Data?)
            let coarse = try #require(surface.drawingPixels(heightScale: nil, includesNormals: true).normals)
            for z in 0..<16 { for x in 0..<16 {
                let i = (z * 16 + x) * 4, j = ((z + 496) * 512 + x + 496) * 4
                #expect(Array(bytes[i..<(i + 4)]) == Array(coarse[j..<(j + 4)]))
            } }
            let pixels = try ItemPictureFixture.pixels(detail.image)
            for (x, z) in [(0, 0), (1, 1), (2, 1)] {
                let expected = DarkSpots.color(MapColor(0xff0000), status: status, x: x, z: z)
                #expect(pixels.color(x * 16 + 2, z * 16 + 2) == [expected.red, expected.green, expected.blue, 255])
            }
        }
        await assets.close()
    }

    @Test func clockChangesRelightCloseUpPicturesWithoutRebuildingThemAndDarkSpotsStayVisible() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let savedLighting = TestSavedLighting()
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
                          cacheDirectory: root.appendingPathComponent("tiles"))
        defer { map.close() }
        let artwork = try fixture.library()
        gameResources.value = MapGameResources(data: artwork.data, artwork: artwork, biomeColors: nil)
        savedLighting.value = try lighting(night: false)
        map.viewport.scale = 8
        let size = CGSize(width: 128, height: 128), chunk = ChunkPosition(x: -1, z: -1)
        map.requestTiles(visibleIn: size)
        await map.waitUntilIdle(); await map.waitForRenders()
        let image = try #require(map.detailImages[chunk])
        #expect(image.normals != nil)
        func copiedPixel() throws -> UInt32? {
            let copy = try #require(MapImage.render(map, content: MapContent(gameNames: .unavailable), portalStatus: { _ in nil },
                size: size, scale: 1, colorScheme: .light, locale: .init(identifier: "en_US")))
            return try #require(ItemTexture(png: copy.data)).rgb(at: .init(1, 1))
        }
        let day = try copiedPixel()
        savedLighting.value = try lighting(night: true)
        #expect(!map.isLoading && map.detailImages[chunk] === image)
        #expect(try copiedPixel() != day)
        map.setLightingMode(.daylight)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.detailImages[chunk]?.normals == nil)
        #expect(try copiedPixel() == 0xff0000)
        map.setDarkSpots(true)
        await map.waitUntilIdle(); await map.waitForRenders()
        let unknown = try #require(map.detailImages[chunk])
        let color = DarkSpots.color(MapColor(0xff0000), status: .unknown, x: 0, z: 0)
        #expect(try copiedPixel() == UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue))
        map.setLightingMode(.savedTime)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.detailImages[chunk]?.normals != nil && map.detailImages[chunk] !== unknown)
        let nightWithSpots = try copiedPixel()
        map.setDarkSpots(false)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(try copiedPixel() != nightWithSpots)
    }

    @Test(.timeLimit(.minutes(1))) func shadowsCoverBothResolutionsOnceIncludingTransparentDetailAndCopiedImages() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let region = RegionPosition(x: -1, z: -1), chunk = ChunkPosition(x: -1, z: -1)
        let white = try #require(CGImage.rgba(Array(repeating: 255, count: 512 * 512 * 4), width: 512, height: 512))
        var heights = Array(repeating: Int32(0), count: 512 * 512)
        for x in 496..<512 { heights[503 * 512 + x] = 8 }
        let shadowHeights = heights
        var pixels: [UInt8] = []
        for _ in 0..<256 {
            for x in 0..<256 {
                let alpha: UInt8 = x < 64 ? 0 : x < 128 ? 128 : 255
                pixels.append(contentsOf: [alpha, alpha, alpha, alpha])
            }
        }
        let detail = MapTileImage(try #require(CGImage.rgba(pixels, width: 256, height: 256)))
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
            renderTile: { renderer, position in
                guard var tile = try await renderer.tile(for: position) else { return nil }
                tile.full = MapTileImage(white); tile.preview = MapTileImage(white)
                tile.heights = shadowHeights
                return tile
            }, renderDetail: { _, _, _, _, _ in detail })
        defer { map.close() }
        map.viewport.scale = 8
        let size = CGSize(width: 128, height: 128)
        map.requestTiles(visibleIn: size)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.shadowImages[region] != nil && map.detailImages.isEmpty)
        func screen() throws -> [UInt8] {
            let view = Canvas { context, size in
                MapView.drawMap(map, content: MapContent(gameNames: .unavailable), portalStatus: { _ in nil }, displayScale: 1, in: context, size: size)
            }.frame(width: size.width, height: size.height)
            return try ItemPictureFixture.pixels(#require(ImageRenderer(content: view).cgImage)).bytes
        }
        func copy(_ contrast: ColorSchemeContrast) throws -> [UInt8] {
            let image = try #require(MapImage.render(map, content: MapContent(gameNames: .unavailable), portalStatus: { _ in nil },
                size: size, scale: 1, colorScheme: .light, locale: .init(identifier: "en_US"), contrast: contrast))
            return try #require(ItemTexture(png: image.data)).pixels
        }
        let ordinary = try screen()
        let ordinaryCopy = try copy(.standard), ordinaryContrastCopy = try copy(.increased)
        for x in [17, 49, 81] { #expect(ordinary[(65 * 128 + x) * 4] < 255) }
        #expect(ordinaryCopy != ordinaryContrastCopy)
        let assets = try fixture.library()
        gameResources.value = MapGameResources(data: assets.data, artwork: assets, biomeColors: nil)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.detailImages[chunk]?.picture === detail)
        // White detail over white terrain is unchanged before the shadow. Applying a mask to
        // both resolutions would double-darken transparent or partially transparent areas.
        #expect(try screen() == ordinary)
        #expect(try copy(.standard) == ordinaryCopy)
        #expect(try copy(.increased) == ordinaryContrastCopy)
        map.setCastsShadows(false)
        await map.waitUntilIdle(); await map.waitForRenders()
        #expect(map.detailImages[chunk]?.picture === detail)
        let unshadowed = try copy(.standard)
        for x in [17, 49, 81] { #expect(unshadowed[(65 * 128 + x) * 4] == 255) }
        map.close(); await map.waitForRenders(); await assets.close()
    }

    @Test(.timeLimit(.minutes(1))) func changingLightingRejectsAnOldCloseUpPicture() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let gate = AsyncReadGate<MapTileImage?>()
        let savedLighting = TestSavedLighting()
        let gameResources = TestGameResources()
        let map = MapModel(definitions: { .unknown }, gameResources: { gameResources.value }, savedLighting: { savedLighting.value }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -8, y: -8),
            renderDetail: { _, _, _, _, saved in await gate.read(saved ? "saved" : "daylight") })
        defer { map.close() }
        let artwork = try fixture.library()
        gameResources.value = MapGameResources(data: artwork.data, artwork: artwork, biomeColors: nil)
        savedLighting.value = try lighting(night: true)
        map.viewport.scale = 8
        map.requestTiles(visibleIn: CGSize(width: 64, height: 64))
        await gate.waitForRequest("saved")
        map.setLightingMode(.daylight)
        await gate.waitForCancellation("saved"); await gate.waitForRequest("daylight")
        let old = MapTileImage(try #require(CGImage.rgba([255, 0, 0, 255], width: 1, height: 1)))
        let current = MapTileImage(try #require(CGImage.rgba([0, 255, 0, 255], width: 1, height: 1)))
        await gate.finish("daylight", with: current)
        await map.waitUntilIdle()
        await gate.finish("saved", with: old)
        await map.waitForRenders()
        #expect(map.detailImages[.init(x: -1, z: -1)]?.picture === current)
    }

    private func lighting(night: Bool) throws -> MapLighting {
        let time = try JSONDecoder().decode(DimensionTime.self, from: Data(#"{"has_skylight":true}"#.utf8))
        let saved = try #require(SkyLighting(sunAngle: night ? 180 : 0, moonAngle: 0,
            skyLightFactor: night ? 0.24 : 1, skyLightColor: night ? SIMD3(0.48, 0.48, 1) : SIMD3(repeating: 1),
            moonPhase: .fullMoon))
        return try #require(MapLighting(saved: saved, time: time))
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
        try json("assets/test/blockstates/custom.json", ["variants": ["": ["model": "test:block/red"]]])
        return try ItemPictureFixture(extraFiles: files)
    }
}
