import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PartialBlockLayersTests {
    @Test func coverageComesFromGeometryAlphaAndGeneratedRendererFacts() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let assets = try fixture.library()
        let states = ["test:ground", "test:torch", "test:wall", "test:flower", "minecraft:barrier", "minecraft:chest", "test:empty", "test:missing"].map { BlockState($0) }
        let expected: [MapBlockCoverage] = [.covers, .partial(opacity: 1 / 64), .partial(opacity: 1 / 4),
            .partial(opacity: 128 / 255), .none, .unavailable, .unavailable, .unavailable]
        let coverage = try await assets.mapCoverage(for: states)
        #expect(coverage == expected)
        #expect(assets.cachedMapCoverage(for: states) == expected)
        #expect(try await assets.mapColors(for: [BlockState("test:flower")]) == [MapColor(0xff0000)])
        await assets.close()
        #expect(assets.cachedMapCoverage(for: states) == nil)
        await #expect(throws: CancellationError.self) { try await assets.mapCoverage(for: states) }
    }

    @Test(arguments: ["test:torch", "test:wall", "test:flower"])
    func partialBlocksRetainGroundAtBothZoomLevels(_ id: String) async throws {
        let fixture = try fixture(), root = try world([15: id])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library()
        let renderer = RegionTileRenderer(dimension: dimension, gameAssets: assets)
        let tile = try #require(try await renderer.tile(for: .init(x: 0, z: 0)))
        let surface = try #require(tile.detail), chunk = try #require(surface.detail.chunks[0])
        #expect(surface.heights[8 * 512 + 8] == 12)
        #expect(chunk.materials[Int(chunk.indices[136])].request.state.id == "test:ground")
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detail.image)
        if id == "test:flower" {
            #expect(pixels.color(129, 129) == [128, 127, 0, 255])
            #expect(pixels.color(136, 136) == [128, 127, 0, 255])
        } else {
            #expect(pixels.color(129, 129) == [0, 255, 0, 255])
            #expect(pixels.color(136, 136) == (id == "test:torch" ? [255, 0, 0, 255] : [0, 0, 255, 255]))
        }
        let map = try ItemPictureFixture.pixels(tile.full.image)
        let expected: [UInt8] = id == "test:torch" ? [4, 251, 0, 255] : id == "test:wall" ? [0, 191, 64, 255] : [128, 127, 0, 255]
        #expect(map.color(8, 8) == expected)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let readout = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0)?[136])
        #expect(readout.id == id && readout.y == 15)
    }

    @Test func stackedLayersKeepTheirOrderAndTheirCacheNeedsNoSecondWorldRead() async throws {
        let fixture = try fixture(), root = try world([15: "test:torch", 14: "test:wall"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library(), region = RegionPosition(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: root.appendingPathComponent("tiles")),
            savesInBackground: false, gameAssets: assets)
        let cold = try #require(try await renderer.tile(for: region))
        let hit = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(cold.full.image).bytes == ItemPictureFixture.pixels(hit.full.image).bytes)
        let surface = try #require(try await renderer.detail(for: region))
        #expect(surface.detail == cold.detail?.detail)
        try FileManager.default.removeItem(at: dimension.regionURL(at: region))
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detail.image)
        #expect(pixels.color(129, 129) == [0, 255, 0, 255])
        #expect(pixels.color(133, 133) == [0, 0, 255, 255])
        #expect(pixels.color(136, 136) == [255, 0, 0, 255])
    }

    @Test func invisibleModelsAreSkippedButCodeRenderedBlocksAndNoGamePresentationRemain() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let assets = try fixture.library()
        for id in ["minecraft:barrier", "minecraft:chest", "test:ground", "test:torch"] {
            let root = try world([15: id])
            defer { try? FileManager.default.removeItem(at: root) }
            let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
            let file = try #require(try dimension.region(x: 0, z: 0))
            let renderer = RegionTileRenderer(dimension: dimension, gameAssets: assets)
            let readout = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0)?[0])
            #expect(readout.id == (id == "minecraft:barrier" ? "test:ground" : id))
            if id == "minecraft:chest" || id == "test:ground" { #expect(readout.y == 15) }
            let fallback = RegionTileRenderer(dimension: dimension)
            #expect(try await fallback.topBlocks(in: file, localX: 0, localZ: 0)
                == RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
            let fallbackTile = try #require(try await fallback.tile(for: .init(x: 0, z: 0)))
            #expect(fallbackTile.detail == nil)
        }
    }

    @Test func malformedLayerSidecarsAreRejectedWithoutLosingTheValidRoundtrip() async throws {
        let fixture = try fixture(), root = try world([15: "test:torch", 14: "test:wall"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library()
        let tile = try #require(try await RegionTileRenderer(dimension: dimension, gameAssets: assets).tile(for: .init(x: 0, z: 0)))
        let detail = try #require(tile.detail?.detail), encoded = try #require(detail.encoded())
        #expect(MapSurfaceDetail.decoded(encoded) == detail)
        let payload = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        let chunks = try #require(payload["chunks"] as? [[String: Any]])
        let original = try #require(chunks.first?["overlays"] as? Data)
        try #require(original.count >= 20)
        var malformed: [Data] = [Data(original.dropLast()), original + original, original + Data([0])]
        for (offset, bytes) in [(1, [UInt8(2)]), (2, [0, 0]), (7, [1]), (8, [255, 255]), (10, [0, 0, 0, 128])] {
            var changed = original
            changed.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            malformed.append(changed)
        }
        for records in malformed {
            var changed = payload, changedChunks = chunks
            changedChunks[0]["overlays"] = records
            changed["chunks"] = changedChunks
            let data = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
            #expect(MapSurfaceDetail.decoded(data) == nil)
        }
        await assets.close()
    }

    @Test func lilyPadsKeepTheWaterLookBetweenTheirPixels() async throws {
        let fixture = try fixture(), root = try world([15: "test:lily", 14: "minecraft:water", 13: "minecraft:water"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let assets = try fixture.library()
        let renderer = RegionTileRenderer(dimension: dimension, gameAssets: assets)
        let tile = try #require(try await renderer.tile(for: .init(x: 0, z: 0)))
        let surface = try #require(tile.detail)
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: true))
        let waterRoot = try world([14: "minecraft:water", 13: "minecraft:water"])
        defer { try? FileManager.default.removeItem(at: waterRoot) }
        let waterDimension = try #require(try World(contentsOf: waterRoot).dimension("overworld"))
        let water = try #require(try await RegionTileRenderer(dimension: waterDimension, gameAssets: assets).tile(for: .init(x: 0, z: 0)))
        let waterPixel = try ItemPictureFixture.pixels(water.full.image).color(8, 8)
        let pixels = try ItemPictureFixture.pixels(detail.image)
        #expect(pixels.color(137, 137) == waterPixel)
        #expect(pixels.color(129, 129) == [255, 0, 0, 255])
        #expect(surface.heights[8 * 512 + 8] == 14)
    }

    @Test func hidingLayersRevealsTheNextLayerAndThenTheGround() async throws {
        let fixture = try fixture(), root = try world([15: "test:torch", 14: "test:wall"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0)), assets = try fixture.library()
        var renderer = RegionTileRenderer(dimension: dimension, blockFilter: .init(hiddenIDs: ["test:torch"]), gameAssets: assets)
        let wall = try #require(try await renderer.tile(for: .init(x: 0, z: 0)))
        #expect(try ItemPictureFixture.pixels(wall.full.image).color(8, 8) == [0, 191, 64, 255])
        let top = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0)?[136])
        #expect(top.id == "test:wall" && top.y == 14)
        let surface = try #require(wall.detail)
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detail.image)
        #expect(pixels.color(129, 129) == [0, 255, 0, 255])
        #expect(pixels.color(136, 136) == [0, 0, 255, 255])

        renderer.blockFilter = .init(hiddenIDs: ["test:torch", "test:wall"])
        let ground = try #require(try await renderer.tile(for: .init(x: 0, z: 0)))
        #expect(try ItemPictureFixture.pixels(ground.full.image).color(8, 8) == [0, 255, 0, 255])
        let exposed = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0)?[136])
        #expect(exposed.id == "test:ground" && exposed.y == 12)
        #expect(ground.detail?.detail.chunks[0]?.overlays.isEmpty == true)
    }

    @Test func waterloggedPartialBlocksKeepTheirWaterDepthAndShowWaterInTheirGaps() async throws {
        let palette: [NBT] = [.compound(["Name": .string("test:ground")]), .compound(["Name": .string("minecraft:water")]), .compound([
            "Name": .string("minecraft:oak_fence"), "Properties": .compound(["waterlogged": .string("true")])])]
        let section = Fixtures.section(y: 0, palette: palette,
            indices: (0..<4096).map { $0 / 256 == 15 ? 2 : $0 / 256 > 12 ? 1 : 0 })
        let root = try TestWorld.make(chunks: [.init(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: SaveVersion.java26_3, sections: [section]))])
        let fixture = try fixture(), waterRoot = try world([15: "minecraft:water", 14: "minecraft:water", 13: "minecraft:water"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: waterRoot) }
        let saved = try World(contentsOf: root), assets = try fixture.library()
        let dimension = try #require(saved.dimension("overworld")), game = try #require(try GameAssets(contentsOf: fixture.jar))
        let context = MapSurfaceContext(settings: nil, water: try WorldDefinitions.read(saved, assets: game).water)
        let renderer = RegionTileRenderer(dimension: dimension, surfaceContext: context, gameAssets: assets)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let top = try #require(try await renderer.topBlocks(in: file, localX: 0, localZ: 0)?[136])
        #expect(top.id == "minecraft:oak_fence" && top.y == 15 && top.waterDepth == 3)
        let tile = try #require(try await renderer.tile(for: .init(x: 0, z: 0))), surface = try #require(tile.detail)
        #expect(surface.heights[8 * 512 + 8] == 15)
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: false))
        let waterDimension = try #require(try World(contentsOf: waterRoot).dimension("overworld"))
        let waterTile = try #require(try await RegionTileRenderer(dimension: waterDimension, surfaceContext: context, gameAssets: assets).tile(for: .init(x: 0, z: 0)))
        let pixels = try ItemPictureFixture.pixels(detail.image)
        let water = try ItemPictureFixture.pixels(waterTile.full.image).color(8, 8)
        #expect(pixels.color(129, 129) == water)
        #expect(pixels.color(136, 136) == [0, 0, 255, 255])
    }

    @Test func fullBlocksKeepTheirColorHeightAndPicture() async throws {
        let fixture = try fixture(), root = try world([15: "test:ground"])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld")), assets = try fixture.library()
        let tile = try #require(try await RegionTileRenderer(dimension: dimension, gameAssets: assets).tile(for: .init(x: 0, z: 0)))
        let surface = try #require(tile.detail)
        #expect(surface.heights[8 * 512 + 8] == 15)
        #expect(surface.detail.chunks[0]?.overlays.isEmpty == true)
        #expect(try ItemPictureFixture.pixels(tile.full.image).color(8, 8) == [0, 255, 0, 255])
        let detail = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: assets, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detail.image)
        #expect(pixels.color(129, 129) == [0, 255, 0, 255] && pixels.color(136, 136) == [0, 255, 0, 255])
    }

    @Test func excessiveTranslucentTowersKeepAVisibleFlatSurface() throws {
        let sections = (0..<20).map { Fixtures.section(y: $0, palette: [.string("test:torch")], indices: []) }
        let chunk = try Chunk(nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3, sections: sections))
        var colors = RegionTileRenderer.ColorSections(chunk, coverage: [BlockState("test:torch"): .partial(opacity: 1 / 64)])
        let columns = colors.topColumns()
        #expect(columns.count == 256)
        #expect(columns.allSatisfy { $0?.y == 319 && $0?.layers.isEmpty == true })
    }

    private func world(_ layers: [Int: String]) throws -> URL {
        let palette = Array(Set(layers.values).union(["test:ground", "minecraft:air"])).sorted()
        return try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: palette, index: { _, y, _ in
            palette.firstIndex(of: layers[y] ?? (y <= 12 ? "test:ground" : "minecraft:air"))!
        })])
    }

    private func fixture() throws -> ItemPictureFixture {
        var files: [String: Data] = [:]
        func json(_ path: String, _ object: Any) throws { files[path] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        try json("data/minecraft/tags/fluid/water.json", ["values": ["minecraft:water", "minecraft:flowing_water"]])
        func block(_ id: String, _ elements: [[String: Any]]) throws {
            let parts = id.split(separator: ":")
            try json("assets/\(parts[0])/blockstates/\(parts[1]).json", ["variants": ["": ["model": id]]])
            try json("assets/\(parts[0])/models/\(parts[1]).json", ["elements": elements,
                "textures": ["green": "test:green", "red": "test:red", "blue": "test:blue", "flower": "test:flower", "lily": "test:lily"]])
        }
        func top(_ texture: String, from: [Int] = [0, 0, 0], to: [Int] = [16, 16, 16]) -> [String: Any] {
            ["from": from, "to": to, "faces": ["up": ["texture": "#" + texture, "uv": [0, 0, 16, 16]]]]
        }
        let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [0, 0, 255, 255], clear: [UInt8] = [0, 0, 0, 0]
        for (id, pixels) in ["red": red + red + red + red, "green": green + green + green + green,
                             "blue": blue + blue + blue + blue, "flower": red + clear + red + clear,
                             "lily": red + clear + clear + clear] {
            files["assets/test/textures/\(id).png"] = try ItemPictureFixture.png(pixels)
        }
        try block("test:ground", [top("green")])
        try block("test:torch", [top("red", from: [7, 0, 7], to: [9, 10, 9])])
        try block("test:wall", [top("blue", from: [4, 0, 4], to: [12, 16, 12])])
        try block("minecraft:oak_fence", [top("blue", from: [4, 0, 4], to: [12, 16, 12])])
        try block("test:lily", [top("lily", to: [16, 1, 16])])
        try block("test:flower", [["from": [0, 0, 8], "to": [16, 16, 8], "faces": [
            "north": ["texture": "#flower", "uv": [0, 0, 16, 16]], "south": ["texture": "#flower", "uv": [0, 0, 16, 16]]]]])
        for id in ["minecraft:barrier", "minecraft:chest", "minecraft:water", "test:empty"] { try block(id, []) }
        files["assets/minecraft/textures/block/water_still.png"] = try ItemPictureFixture.png(Array(repeating: [UInt8](arrayLiteral: 0, 0, 128, 128), count: 4).flatMap { $0 })
        return try ItemPictureFixture(extraFiles: files)
    }
}
