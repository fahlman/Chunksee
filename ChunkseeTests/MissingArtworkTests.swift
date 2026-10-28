import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MissingArtworkTests {
    @Test func absentModelsAndTexturesShareTheGamePatternAtBothMapScales() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states = ["missing_texture", "missing_model", "no_definition"].map { BlockState("test:" + $0) }
        #expect(try await library.mapColors(for: states) == Array(repeating: MapColor(0x7c007c), count: 3))
        var indices = [UInt16](repeating: .max, count: 256)
        var positions = [BlockPosition?](repeating: nil, count: 256)
        for index in states.indices {
            indices[index] = UInt16(index)
            positions[index] = .init(blockX: index, blockY: 15, blockZ: 0)
        }
        let requests = states.map { MapBlockColorRequest(state: $0) }
        let first = try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        for index in states.indices {
            let texture = try #require(first[index])
            #expect(texture.width == 16 && texture.height == 16)
            #expect(texture.rgb(at: .init(2, 2)) == 0)
            #expect(texture.rgb(at: .init(14, 2)) == 0xf800f8)
            #expect(texture.rgb(at: .init(2, 14)) == 0xf800f8)
            #expect(texture.rgb(at: .init(14, 14)) == 0)
        }
        let warm = try await library.mapTextures(requests: requests, indices: indices, positions: positions)
        #expect(warm.map { $0?.pixels } == first.map { $0?.pixels })
        #expect(try await library.mapColors(for: [BlockState("test:ordinary")]) == [MapColor(0xff0000)])
        await library.close()
    }

    @Test func itemPicturesUseThePatternAndKeepWarmIdentity() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let stack = ItemStack(id: "test:missing_texture")
        let image = try #require(try await library.picture(for: stack))
        let pixels = try ItemPictureFixture.pixels(image)
        #expect(pixels.color(8, 8) == [0, 0, 0, 255])
        #expect(pixels.color(56, 8) == [248, 0, 248, 255])
        #expect(pixels.color(8, 56) == [248, 0, 248, 255])
        #expect(pixels.color(56, 56) == [0, 0, 0, 255])
        #expect(library.cachedPicture(for: stack) === image)
        let missing = ItemStack(id: "test:no_definition")
        let cube = try #require(try await library.picture(for: missing))
        let cubePixels = try ItemPictureFixture.pixels(cube)
        #expect(cubePixels.color(8, 8) == [0, 0, 0, 255])
        let color = cubePixels.color(56, 8)
        #expect(color[0] > 0 && color[0] == color[2] && color[1] == 0 && color[3] == 255)
        #expect(library.cachedPicture(for: missing) === cube)
        await library.close()
        #expect(library.cachedPicture(for: missing) == nil)
    }

    @Test func unreadableUnsupportedAndIncompleteResourcesKeepTheirFallback() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = try fixture.library()
        let states = ["unreadable", "unsupported", "incomplete", "malformed"].map { BlockState("test:" + $0) }
        #expect(try await library.mapColors(for: states) == [nil, nil, nil, nil])
        #expect(try await library.picture(for: ItemStack(id: "test:unsupported")) == nil)
        #expect(try await library.picture(for: ItemStack(id: "test:unreadable")) == nil)
        // Missing colormap/skin pixels must never sample the marker as a real game color.
        #expect(try await library.textureColor("test:block/gone") == nil)
        await library.close()
    }

    @Test func absentOrUnsupportedAtlasContextDoesNotProveASpriteIsMissing() async throws {
        for atlas in [0, 1] {
            let fixture = try fixture(atlas: atlas)
            defer { fixture.remove() }
            let library = try fixture.library()
            #expect(try await library.mapColors(for: [BlockState("test:missing_texture")]) == [nil])
            #expect(try await library.picture(for: ItemStack(id: "test:missing_texture")) == nil)
            #expect(try await library.mapColors(for: [BlockState("test:ordinary")]) == [MapColor(0xff0000)])
            await library.close()
        }
    }

    @Test func theRealTerrainAndDetailPathsKeepMissingBlocksVisible() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["test:no_definition"], index: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let library = try fixture.library(), region = RegionPosition(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: nil, gameData: library.data, gameArtwork: library)
        let tile = try #require(try await renderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(tile.full.image).color(8, 8) == [124, 0, 124, 255])
        let surface = try #require(tile.detail)
        let detailed = try #require(try await MapDetailRenderer.render(.init(x: 0, z: 0), surface: surface,
            assets: library, heightScale: nil, usesSavedLighting: false))
        let pixels = try ItemPictureFixture.pixels(detailed.image)
        #expect(pixels.color(2, 2) == [0, 0, 0, 255])
        #expect(pixels.color(14, 2) == [248, 0, 248, 255])
        let fallback = RegionTileRenderer(dimension: dimension, cache: nil)
        let original = try #require(try await fallback.tile(for: region))
        let expected = try #require(BlockColors.color(for: "test:no_definition"))
        #expect(try ItemPictureFixture.pixels(original.full.image).color(8, 8) == [expected.red, expected.green, expected.blue, 255])
        await library.close()
    }

    @Test func choosingGameFilesPreservesMissingTexturesAndDataAcrossArtworkChanges() async throws {
        let fixture = try fixture(), root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["test:missing_texture", "test:no_definition"], index: { x, _, _ in x < 8 ? 0 : 1 })])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(fixture.root)
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let session = WorldSession(resources: resources), map = try #require(session.map)
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        let region = RegionPosition(x: 0, z: 0), point = CGPoint(x: 12, y: 8)
        let data = try #require(map.currentRenderer.gameData), reader = resources.readers["minecraft:overworld"]
        let original = try #require(try await map.currentRenderer.tile(for: region))
        let pixels = try ItemPictureFixture.pixels(original.full.image)
        #expect(pixels.color(4, 8) == [124, 0, 124, 255])
        #expect(pixels.color(12, 8) == [124, 0, 124, 255])
        map.loadTopBlocks(at: point)
        await map.waitForTopBlocks()
        let notice = try #require(map.blockDefinitionNotice(for: map.topBlock(at: point)))
        #expect(map.topBlock(at: CGPoint(x: 4, y: 8))?.hasGameDefinition == true)

        names.minecraft.usesGameArtwork = false
        await resources.waitForRefresh()
        #expect(map.currentRenderer.gameData === data && map.currentRenderer.gameArtwork == nil)
        #expect(resources.readers["minecraft:overworld"] === reader)
        #expect(map.blockDefinitionNotice(for: map.topBlock(at: point)) == notice)
        let fallback = try #require(try await map.currentRenderer.tile(for: region))
        let expected = try #require(BlockColors.color(for: "test:missing_texture"))
        #expect(try ItemPictureFixture.pixels(fallback.full.image).color(4, 8) == [expected.red, expected.green, expected.blue, 255])

        names.minecraft.usesGameArtwork = true
        await resources.waitForRefresh()
        let restored = try #require(try await map.currentRenderer.tile(for: region))
        #expect(try ItemPictureFixture.pixels(restored.full.image).bytes == pixels.bytes)
        #expect(map.currentRenderer.gameData === data && resources.readers["minecraft:overworld"] === reader)
        #expect(map.blockDefinitionNotice(for: map.topBlock(at: point)) == notice)
        session.close()
        await session.waitUntilClosed()
        names.minecraft.forget()
        await names.minecraft.waitUntilIdle()
    }

    @Test func blockInformationUsesDefinitionEvidenceAndRefreshesWhenGameFilesChange() async throws {
        let absent = try fixture(extra: ["version.json": ItemPictureFixture.json(["id": "Selected Game", "world_version": 5023])]),
            present = try fixture(extra: [
            "assets/test/blockstates/no_definition.json": ItemPictureFixture.json(["variants": ["": ["model": "test:block/gone"]]])
        ])
        defer { absent.remove(); present.remove() }
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["test:no_definition"], index: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let point = CGPoint(x: 8, y: 8)
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: point, cacheDirectory: nil)
        defer { map.close() }
        let absentLibrary = try absent.library(), presentLibrary = try present.library()
        map.setGameResources(data: absentLibrary.data, artwork: absentLibrary)
        await map.waitForTopBlocks()
        let block = try #require(map.topBlock(at: point))
        #expect(block.id == "test:no_definition" && block.hasGameDefinition == false)
        let notice = try #require(map.blockDefinitionNotice(for: block))
        #expect(notice.label() == "Minecraft Selected Game doesn't recognize this block")
        #expect(MapView.accessibilityReadout(map: map, content: .init()).contains(notice.accessibilityLabel()))
        map.setGameResources(data: absentLibrary.data, artwork: nil)
        await map.waitForTopBlocks()
        #expect(map.blockDefinitionNotice(for: map.topBlock(at: point)) == notice)
        map.setGameResources(data: presentLibrary.data, artwork: presentLibrary)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: point)?.hasGameDefinition == true)
        #expect(map.blockDefinitionNotice(for: map.topBlock(at: point)) == nil)
        #expect(!MapView.accessibilityReadout(map: map, content: .init()).contains(notice.accessibilityLabel()))
        map.loadTopBlocks(at: point)
        map.setGameResources(data: nil, artwork: nil)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: point)?.hasGameDefinition == nil)
        #expect(map.topBlock(at: point)?.id == "test:no_definition")
        await absentLibrary.close()
        await presentLibrary.close()
    }

    @Test func noticeUsesSelectedMetadataAndItsApprovedUnnamedFallback() {
        let named = BlockDefinitionNotice(gameName: "  Selected Release  ")
        #expect(named.label() == "Minecraft Selected Release doesn't recognize this block")
        #expect(named.help() == "Minecraft Selected Release would remove it when this area loads.")
        #expect(named.accessibilityLabel() == "Minecraft Selected Release doesn't recognize this block. It would remove it when this area loads.")
        let unnamedVersions: [String?] = [nil, "", " "]
        for name in unnamedVersions {
            let unnamed = BlockDefinitionNotice(gameName: name)
            #expect(unnamed.label() == "Minecraft doesn't recognize this block")
            #expect(unnamed.help() == "Minecraft would remove it when this area loads.")
            #expect(unnamed.accessibilityLabel() == "Minecraft doesn't recognize this block. It would remove it when this area loads.")
        }
    }

    private func fixture(atlas: Int = 2, extra: [String: Data] = [:]) throws -> ItemPictureFixture {
        var files = extra
        func json(_ path: String, _ value: Any) throws { files[path] = try ItemPictureFixture.json(value) }
        for (name, texture) in [("missing_texture", "test:block/gone"), ("unreadable", "test:block/broken"), ("ordinary", "test:item/red")] {
            try json("assets/test/blockstates/\(name).json", ["variants": ["": ["model": "test:block/" + name]]])
            try json("assets/test/models/block/\(name).json", ["textures": ["top": texture],
                "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["up": ["texture": "#top"]]]]])
            try json("assets/test/items/\(name).json", ["model": ["type": "model", "model": "test:item/" + name]])
            try json("assets/test/models/item/\(name).json", ["parent": "minecraft:builtin/generated", "gui_light": "front", "textures": ["layer0": texture]])
        }
        try json("assets/test/blockstates/missing_model.json", ["variants": ["": ["model": "test:block/absent"]]])
        try json("assets/test/blockstates/unsupported.json", ["variants": ["": ["model": "test:item/ordinary"]]])
        try json("assets/test/blockstates/incomplete.json", ["variants": ["kind=one": ["model": "test:block/ordinary"], "kind=two": ["model": "test:block/ordinary"]]])
        try json("assets/test/items/unsupported.json", ["model": ["type": "test:future_renderer"]])
        files["assets/test/blockstates/malformed.json"] = Data("not JSON".utf8)
        files["assets/test/textures/block/broken.png"] = Data("not PNG".utf8)
        if atlas != 0 {
            for name in ["blocks", "items"] {
                let sources: [[String: Any]] = atlas == 1 ? [["type": "test:future_source"]] : []
                try json("assets/minecraft/atlases/\(name).json", ["sources": sources])
            }
        }
        return try ItemPictureFixture(extraFiles: files)
    }
}
