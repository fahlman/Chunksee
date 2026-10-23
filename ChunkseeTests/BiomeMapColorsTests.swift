import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BiomeMapColorsTests {
    @Test func worldsShareTheArchiveButKeepTheirOwnResolvedColorsAndStableKeys() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let first = try world(), second = try world()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try pack(at: first, grass: 0x123456)
        try pack(at: second, grass: 0xabcdef)
        let library = try fixture.library()
        let a = try await library.biomeColors(in: World(contentsOf: first))
        let b = try await library.biomeColors(in: World(contentsOf: second))
        #expect(a.biome("test:a").color(.grass, x: 0, z: 0) == 0x123456)
        #expect(b.biome("test:a").color(.grass, x: 0, z: 0) == 0xabcdef)
        #expect(a.sourceKey != b.sourceKey)
        try level(at: first, packs: ["vanilla", "file/override"], name: "Renamed during autosave")
        let unchanged = try await library.biomeColors(in: World(contentsOf: first))
        #expect(a.sourceKey == unchanged.sourceKey)
        try level(at: first, packs: ["vanilla"])
        let removed = try await library.biomeColors(in: World(contentsOf: first))
        #expect(removed.biome("test:a").color(.grass, x: 0, z: 0) == 0xff0000)
        #expect(removed.sourceKey != a.sourceKey)
        #expect(removed.biome("test:missing").color(.grass, x: 0, z: 0) == nil)
        #expect(removed.biome("test:climate").color(.grass, x: 0, z: 0) == 0x00ff00)
        await library.close()
    }

    @Test func terrainUsesEachColumnsBiomeAtTheSelectedCutawayHeight() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let chunk = chunk(palette: [.string("minecraft:grass_block")],
                          blocks: { _, _, _ in 0 }, biomes: { x, y, _ in y >= 8 && x >= 8 ? 1 : 0 })
        let url = try world(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        let surface = try await pixels(renderer)
        #expect(surface.color(2, 2) == [255, 0, 0, 255])
        #expect(surface.color(12, 2) == [0, 0, 255, 255])
        #expect(try await pixels(renderer).bytes == surface.bytes)
        renderer.cutawayY = 7
        let cutaway = try await pixels(renderer)
        #expect(cutaway.color(2, 2) == [255, 0, 0, 255] && cutaway.color(12, 2) == [255, 0, 0, 255])
        renderer.gameAssets = nil
        renderer.biomeColors = nil
        let fallback = try await pixels(renderer)
        #expect(fallback.color(2, 2) == [124, 189, 107, 255])
        await library.close()
    }

    @Test func upperPlantsAndUnderwaterFloorsSampleTheirOwnBiomeHeight() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let upper: NBT = .compound(["id": .string("minecraft:tall_grass"), "properties": .compound(["half": .string("upper")])])
        let plant = chunk(palette: [upper], blocks: { _, _, _ in 0 }, biomes: { _, y, _ in y >= 12 ? 1 : 0 })
        let water = chunk(palette: [.string("minecraft:grass_block"), .string("minecraft:water")],
                          blocks: { _, y, _ in y >= 12 ? 1 : 0 }, biomes: { _, y, _ in y >= 12 ? 1 : 0 })
        let first = try world(chunks: [plant]), second = try world(chunks: [water])
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let library = try fixture.library()
        var renderer = RegionTileRenderer(dimension: try #require(try World(contentsOf: first).dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: World(contentsOf: first))
        renderer.cutawayY = 12
        #expect(try await pixels(renderer).color(4, 4) == [255, 0, 0, 255]) // y 11, below the upper plant.
        var underwater = RegionTileRenderer(dimension: try #require(try World(contentsOf: second).dimension("overworld")))
        underwater.gameAssets = library
        underwater.biomeColors = try await library.biomeColors(in: World(contentsOf: second))
        let color = try await pixels(underwater).color(4, 4)
        // Red floor at y 11 under green water at y 15; using the water's biome for the
        // floor would produce blue instead. The existing depth blend remains in place.
        #expect(color[0] > color[1] && color[1] > 0 && color[2] == 0 && color[3] == 255)
        await library.close()
    }

    @Test func leavesAndVinesUseFoliageWhileSpruceKeepsItsFixedTint() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let blocks = ["grass_block", "oak_leaves", "vine", "spruce_leaves"].map { NBT.string("minecraft:" + $0) }
        let url = try world(chunks: [chunk(palette: blocks, blocks: { x, _, _ in x / 4 }, biomes: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        let image = try await pixels(renderer)
        #expect(image.color(2, 2) == [255, 0, 0, 255])
        #expect(image.color(6, 2) == [0, 255, 0, 255] && image.color(10, 2) == [0, 255, 0, 255])
        #expect(image.color(14, 2) == [97, 153, 97, 255])
        await library.close()
    }

    @Test func swampGrassUsesAbsoluteCoordinatesInNegativeRegions() async throws {
        let biome = try ItemPictureFixture.json(["temperature": 0.8, "downfall": 0.9,
            "effects": ["water_color": 0x617b64, "grass_color_modifier": "swamp"]])
        let fixture = try fixture(extraFiles: ["data/test/worldgen/biome/a.json": biome])
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(x: -7, z: -7, palette: [.string("minecraft:grass_block")],
            blocks: { _, _, _ in 0 }, biomes: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        let colors = try await library.biomeColors(in: world)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = colors
        let image = try ItemPictureFixture.pixels(#require(try await renderer.image(for: .init(x: -1, z: -1))))
        // The official 26.3 probe gives 0x4c763c at (-100, -100). In region (-1, -1)
        // that is pixel (412, 412), inside chunk (-7, -7).
        #expect(image.color(412, 412) == [76, 118, 60, 255])
        await library.close()
    }

    @Test func biomeNamesAndMissingDefinitionsKeepTheirMeaningWithinOneChunk() async throws {
        let fixture = try fixture(extraFiles: ["data/minecraft/worldgen/biome/plains.json":
            definition(grass: 0x123456, foliage: 0xabcdef, water: 0x789abc)])
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(palette: [.string("minecraft:grass_block")],
            blocks: { _, _, _ in 0 }, biomes: { x, _, _ in x / 4 },
            biomeIDs: ["plains", "minecraft:plains", "test:missing", "not an id"], biomeBits: 2)])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        let image = try await pixels(renderer)
        #expect(image.color(2, 2) == [18, 52, 86, 255])
        #expect(image.color(6, 2) == image.color(2, 2))
        #expect(image.color(10, 2) == [124, 189, 107, 255])
        #expect(image.color(14, 2) == image.color(10, 2))
        await library.close()
    }

    @Test func aBiomeTintAtAnotherFaceIndexKeepsItsColor() async throws {
        let fixture = try fixture(extraFiles: [
            "assets/test/models/block/petals.json": ItemPictureFixture.json([
                "textures": ["top": "test:item/white"],
                "elements": [["from": [0, 0, 0], "to": [16, 16, 16],
                              "faces": ["up": ["texture": "#top", "tintindex": 1]]]]]),
            "assets/minecraft/blockstates/pink_petals.json": ItemPictureFixture.json([
                "variants": ["": ["model": "test:block/petals"]]])
        ])
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(palette: [.string("minecraft:pink_petals")],
            blocks: { _, _, _ in 0 }, biomes: { x, _, _ in x < 8 ? 0 : 1 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        let image = try await pixels(renderer)
        #expect(image.color(2, 2) == [255, 0, 0, 255])
        #expect(image.color(12, 2) == [0, 0, 255, 255])
        await library.close()
    }

    @Test func changedPackValuesUseDifferentDiskTilesButIdenticalValuesReuseThem() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 }, biomes: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), position = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        let original = try World(contentsOf: url), dimension = try #require(original.dimension("overworld"))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: original)
        let firstKey = renderer.colorSourceKey
        let red = try #require(try await renderer.tile(for: position))
        try pack(at: url, grass: 0x0000ff)
        renderer.biomeColors = try await library.biomeColors(in: World(contentsOf: url))
        let blueKey = renderer.colorSourceKey
        let blue = try #require(try await renderer.tile(for: position))
        #expect(firstKey != blueKey)
        #expect(try ItemPictureFixture.pixels(red.full).color(4, 4) == [255, 0, 0, 255])
        #expect(try ItemPictureFixture.pixels(blue.full).color(4, 4) == [0, 0, 255, 255])
        try pack(at: url, grass: 0x0000ff)
        renderer.biomeColors = try await library.biomeColors(in: World(contentsOf: url))
        #expect(renderer.colorSourceKey == blueKey)
        let hit = try #require(try await renderer.tile(for: position))
        #expect(try ItemPictureFixture.pixels(hit.full).bytes == ItemPictureFixture.pixels(blue.full).bytes)
        let file = dimension.regionURL(at: position)
        #expect(TileCache.key(for: position, regionFile: file, style: .height, colorSource: blueKey)
            == TileCache.key(for: position, regionFile: file, style: .height, colorSource: firstKey))
        await library.close()
    }

    @Test(.timeLimit(.minutes(1))) func dimensionTabsCoalesceColorsAndClosingRejectsAnOldRead() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let first = WorldSession(resources: resources), second = WorldSession(resources: resources)
        let library = try fixture.library()
        let snapshot = try await library.biomeColors(in: resources.world)
        let gate = AsyncReadGate<MapBiomeColors>()
        resources.readBiomeColors = { _, _, _, _ in await gate.read("initial") }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation,
            version: GameAssetVersion(name: resources.world.level.versionName, dataVersion: resources.world.level.dataVersion))
        resources.prepareGameAssets(source)
        resources.setGameAssets(library, source: source)
        await gate.waitForRequest("initial")
        resources.prepareGameAssets(source)
        resources.setGameAssets(library, source: source)
        await gate.finish("initial", with: snapshot)
        await resources.waitForRefresh()
        #expect(await gate.requested == ["initial"])
        #expect(first.map?.currentRenderer.biomeColors?.sourceKey == snapshot.sourceKey)
        #expect(second.map?.currentRenderer.biomeColors?.sourceKey == snapshot.sourceKey)
        resources.refreshDelay = .zero
        resources.readBiomeColors = { _, _, _, _ in await gate.read("late") }
        resources.worldChanged([url.appendingPathComponent("datapacks")])
        await gate.waitForRequest("late")
        resources.close()
        await gate.waitForCancellation("late")
        await gate.finish("late", with: snapshot)
        await resources.waitUntilClosed()
        #expect(first.isClosed && second.isClosed && resources.isClosed)
        #expect(first.map?.currentRenderer.biomeColors == nil && second.map?.currentRenderer.gameAssets == nil)
        await library.close()
    }

    @Test(.timeLimit(.minutes(1))) func anAutosaveCannotDiscardAPendingPackChangeOrPublishAnOlderColorRead() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: url) }
        try pack(at: url, grass: 0xff0000)
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let session = WorldSession(resources: resources), library = try fixture.library()
        resources.refreshDelay = .zero
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation,
            version: GameAssetVersion(name: resources.world.level.versionName, dataVersion: resources.world.level.dataVersion))
        resources.prepareGameAssets(source)
        resources.setGameAssets(library, source: source)
        await resources.waitForRefresh()
        let original = try #require(session.map?.currentRenderer.biomeColors)
        let gate = AsyncReadGate<MapBiomeColors>()
        resources.readBiomeColors = { _, _, _, _ in await gate.read("pack") }
        try pack(at: url, grass: 0x0000ff) // Same enabled pack list, different color content.
        resources.worldChanged([url.appendingPathComponent("datapacks/override/data/test/worldgen/biome/a.json")])
        await gate.waitForRequest("pack")
        resources.readBiomeColors = { world, library, previous, reload in
            _ = await gate.read("metadata")
            return try await WorldResources.readBiomeColors(world, library: library, previous: previous, reload: reload)
        }
        resources.worldChanged([url.appendingPathComponent("level.dat")])
        await gate.waitForRequest("metadata")
        await gate.waitForCancellation("pack")
        await gate.finish("metadata", with: original)
        await gate.finish("pack", with: original)
        await resources.waitForRefresh()
        let updated = session.map?.currentRenderer.biomeColors
        #expect(updated?.sourceKey != original.sourceKey)
        #expect(updated?.biome("test:a").color(.grass, x: 0, z: 0) == 0x0000ff)
        resources.close()
        await resources.waitUntilClosed()
        await library.close()
    }

    private func pixels(_ renderer: RegionTileRenderer) async throws -> ItemPictureFixture.Pixels {
        try ItemPictureFixture.pixels(#require(try await renderer.image(for: .init(x: 0, z: 0))))
    }

    private func chunk(x: Int = 0, z: Int = 0, palette: [NBT], blocks: (Int, Int, Int) -> Int,
                       biomes: (Int, Int, Int) -> Int, biomeIDs: [String] = ["test:a", "test:b"], biomeBits: Int = 1) -> TestWorld.ChunkSpec {
        func indices(_ read: (Int, Int, Int) -> Int) -> [Int] {
            (0..<16).flatMap { y in (0..<16).flatMap { z in (0..<16).map { x in read(x, y, z) } } }
        }
        // 26.3 stores one biome for each 4×4×4 cell, independently of the block palette.
        let biomeCells = (0..<4).flatMap { y in (0..<4).flatMap { z in (0..<4).map { x in biomes(x * 4, y * 4, z * 4) } } }
        let section = Fixtures.section(y: 0, palette: palette, indices: indices(blocks),
            biomes: biomeIDs, biomeIndices: biomeCells, biomeBits: biomeBits)
        return .init(x: x, z: z, nbt: Fixtures.chunk(x: x, z: z, dataVersion: 5023, sections: [section], extra: ["yPos": .int(0)]))
    }

    private func world(chunks: [TestWorld.ChunkSpec] = []) throws -> URL {
        let url = try TestWorld.make(chunks: chunks)
        try level(at: url, packs: ["vanilla"])
        return url
    }

    private func level(at url: URL, packs: [String], name: String = "Biome Map Check") throws {
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string(name), "DataVersion": .int(5023),
            "Version": .compound(["Name": .string("26.3")]),
            "DataPacks": .compound(["Enabled": .list(packs.map(NBT.string))])
        ])]), to: url.appendingPathComponent("level.dat"))
    }

    private func pack(at url: URL, grass: UInt32) throws {
        let pack = url.appendingPathComponent("datapacks/override")
        try Fixtures.write(Array(ItemPictureFixture.json(["pack": ["min_format": 121, "max_format": 121, "description": "Fixture"]])), to: pack.appendingPathComponent("pack.mcmeta"))
        try Fixtures.write(Array(definition(grass: grass, foliage: 0x00ff00, water: 0x0000ff)),
                           to: pack.appendingPathComponent("data/test/worldgen/biome/a.json"))
        try level(at: url, packs: ["vanilla", "file/override"])
    }

    private func definition(grass: UInt32, foliage: UInt32, water: UInt32) throws -> Data {
        try ItemPictureFixture.json(["temperature": 1.0, "downfall": 1.0,
            "effects": ["grass_color": grass, "foliage_color": foliage, "water_color": water]])
    }

    private func fixture(extraFiles: [String: Data] = [:]) throws -> ItemPictureFixture {
        var files: [String: Data] = [:]
        files["data/test/worldgen/biome/a.json"] = try definition(grass: 0xff0000, foliage: 0x00ff00, water: 0x0000ff)
        files["data/test/worldgen/biome/b.json"] = try definition(grass: 0x0000ff, foliage: 0xffff00, water: 0x00ff00)
        files["data/test/worldgen/biome/climate.json"] = try ItemPictureFixture.json([
            "temperature": 1.0, "downfall": 1.0, "effects": ["water_color": 0x0000ff]])
        files["assets/test/models/block/biome.json"] = try ItemPictureFixture.json([
            "textures": ["top": "test:item/white"],
            "elements": [["from": [0, 0, 0], "to": [16, 16, 16], "faces": ["up": ["texture": "#top", "tintindex": 0]]]]])
        for name in ["grass_block", "tall_grass", "oak_leaves", "vine", "spruce_leaves"] {
            files["assets/minecraft/blockstates/\(name).json"] = try ItemPictureFixture.json([
                "variants": ["": ["model": "test:block/biome"]]])
        }
        files.merge(extraFiles) { _, replacement in replacement }
        return try ItemPictureFixture(extraFiles: files)
    }
}
