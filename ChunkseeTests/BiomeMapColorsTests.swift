import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
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
        renderer.blendsBiomeColors = true
        #expect(try await pixels(renderer).bytes == image.bytes) // Uniform biomes and fixed spruce tint stay unchanged.
        await library.close()
    }

    @Test func swampGrassUsesAbsoluteCoordinatesInNegativeRegions() async throws {
        let biome = try ItemPictureFixture.json(["temperature": 0.8, "downfall": 0.9,
            "effects": ["water_color": 0x617b64, "grass_color_modifier": "swamp",
                        "grass_color": 0xffffff, "foliage_color": 0x123456, "dry_foliage_color": 0xabcdef]])
        let fixture = try fixture(extraFiles: ["data/test/worldgen/biome/a.json": biome])
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(x: -7, z: -7, palette: [.string("minecraft:grass_block")],
            blocks: { _, _, _ in 0 }, biomes: { _, _, _ in 0 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        let colors = try await library.biomeColors(in: world)
        let retained = colors.biome("test:a")
        #expect(retained.color(.grass, x: 0, z: 0) == 0x6a7039)
        #expect(retained.color(.grass, x: -100, z: -100) == 0x4c763c)
        for (source, expected) in [(BiomeColor.foliage, UInt32(0x123456)), (.dryFoliage, 0xabcdef), (.water, 0x617b64)] {
            #expect(retained.color(source, x: 0, z: 0) == expected)
            #expect(retained.color(source, x: -100, z: -100) == expected)
        }
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = colors
        let image = try ItemPictureFixture.pixels(#require(try await renderer.image(for: .init(x: -1, z: -1))))
        // The official 26.3 probe gives 0x4c763c at (-100, -100). In region (-1, -1)
        // that is pixel (412, 412), inside chunk (-7, -7).
        #expect(image.color(412, 412) == [76, 118, 60, 255])
        renderer.blendsBiomeColors = true
        let blended = try ItemPictureFixture.pixels(#require(try await renderer.image(for: .init(x: -1, z: -1))))
        var red = 0, green = 0, blue = 0
        for z in -102 ... -98 { for x in -102 ... -98 {
            let value = try #require(retained.color(.grass, x: Int32(x), z: Int32(z)))
            red += Int((value >> 16) & 255); green += Int((value >> 8) & 255); blue += Int(value & 255)
        } }
        #expect(blended.color(412, 412) == [UInt8(red / 25), UInt8(green / 25), UInt8(blue / 25), 255])
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

    @Test func parallelChunksKeepTintDescriptorsWithTheirPaletteAndBiome() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let kinds = ["grass_block", "oak_leaves", "spruce_leaves", "stone"]
        let chunks = (0..<16).map { x in
            let shift = x % kinds.count
            let rotated = Array(kinds[shift...] + kinds[..<shift])
            return chunk(x: x, palette: rotated.map { .string("minecraft:" + $0) },
                         blocks: { x, _, _ in x / 4 }, biomes: { _, _, z in z / 8 })
        }
        let url = try world(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        let serial = try await pixels(renderer)
        renderer.chunkConcurrency = 14
        let parallel = try await pixels(renderer)
        #expect(parallel.bytes == serial.bytes)
        for x in 0..<16 {
            let grass = (kinds.count - x % kinds.count) % kinds.count
            #expect(parallel.color(x * 16 + grass * 4 + 2, 2) == [255, 0, 0, 255])
            #expect(parallel.color(x * 16 + grass * 4 + 2, 10) == [0, 0, 255, 255])
        }
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
        #expect(try ItemPictureFixture.pixels(red.full.image).color(4, 4) == [255, 0, 0, 255])
        #expect(try ItemPictureFixture.pixels(blue.full.image).color(4, 4) == [0, 0, 255, 255])
        try pack(at: url, grass: 0x0000ff)
        renderer.biomeColors = try await library.biomeColors(in: World(contentsOf: url))
        #expect(renderer.colorSourceKey == blueKey)
        let hit = try #require(try await renderer.tile(for: position))
        #expect(try ItemPictureFixture.pixels(hit.full.image).bytes == ItemPictureFixture.pixels(blue.full.image).bytes)
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

    @Test func displacedCellsCrossChunkRegionAndVerticalBoundariesWithIdenticalSerialAndParallelPixels() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let centers = [ChunkPosition(x: -32, z: -32), .init(x: -1, z: 0), .init(x: 0, z: 0), .init(x: 31, z: 31)]
        var positions: Set<ChunkPosition> = []
        for center in centers {
            for x in -1...1 { for z in -1...1 { positions.insert(.init(x: center.x + x, z: center.z + z)) } }
        }
        func blue(_ x: Int, _ y: Int, _ z: Int) -> Bool { ((x >> 2) ^ (y >> 2) ^ (z >> 2)) & 1 == 1 }
        let chunks = positions.map { sampledChunk($0, blue: blue) }
        let url = try world(chunks: chunks, seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library
        renderer.biomeColors = try await library.biomeColors(in: world)
        #expect(renderer.samplesNeighborBiomes)
        let sampler = BiomeSampler(seed: 0)
        for region in Set(centers.map(\.region)) {
            let serial = try ItemPictureFixture.pixels(#require(try await renderer.image(for: region)))
            renderer.chunkConcurrency = 14
            let parallel = try ItemPictureFixture.pixels(#require(try await renderer.image(for: region)))
            #expect(serial.bytes == parallel.bytes)
            for center in centers where center.region == region {
                let origin = try #require(center.blockOrigin)
                for z in 0..<16 { for x in 0..<16 {
                    let cell = try #require(sampler.cellOrigin(at: BlockPosition(blockX: origin.x + x, blockY: 15, blockZ: origin.z + z)))
                    #expect(parallel.color(center.localX * 16 + x, center.localZ * 16 + z)
                        == (blue(cell.x, cell.y, cell.z) ? [0, 0, 255, 255] : [255, 0, 0, 255]))
                } }
            }
            renderer.chunkConcurrency = 1
        }
        renderer.cutawayY = 7
        let slice = try await pixels(renderer)
        for z in 2..<14 { for x in 2..<14 {
            let cell = try #require(sampler.cellOrigin(at: BlockPosition(blockX: x, blockY: 7, blockZ: z)))
            #expect(slice.color(x, z) == (blue(cell.x, cell.y, cell.z) ? [0, 0, 255, 255] : [255, 0, 0, 255]))
        } }
        await library.close()
    }

    @Test func sparseAndDamagedChunksDoNotPreventLaterRowsFromRendering() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let damaged: Set<ChunkPosition> = [.init(x: 0, z: 0), .init(x: 3, z: 2), .init(x: 2, z: 6),
                                          .init(x: 5, z: 31), .init(x: -1, z: 0), .init(x: 32, z: 31)]
        let positions = Set([0, 1, 2, 3, 4, 5, 6, 12, 31].flatMap { z in
            [0, 1, 2, 3, 4, 5, 31].map { x in ChunkPosition(x: x, z: z) }
        }).union([.init(x: -1, z: 1), .init(x: 32, z: 30)])
        let valid = positions.subtracting(damaged)
        func blue(_ x: Int, _ y: Int, _ z: Int) -> Bool { ((x >> 2) ^ (y >> 2) ^ (z >> 2)) & 1 == 1 }
        let chunks = valid.map { sampledChunk($0, blue: blue) }
            + damaged.map { TestWorld.ChunkSpec(x: $0.x, z: $0.z, nbt: .compound([:])) }
        let url = try world(chunks: chunks, seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        let serial = try await pixels(renderer)
        renderer.chunkConcurrency = 14
        let parallel = try await pixels(renderer)
        #expect(serial.bytes == parallel.bytes)
        let sampler = BiomeSampler(seed: 0)
        for position in valid where position.region == RegionPosition(x: 0, z: 0) {
            let origin = try #require(position.blockOrigin)
            for z in [0, 7, 15] { for x in [0, 7, 15] {
                let point = BlockPosition(blockX: origin.x + x, blockY: 15, blockZ: origin.z + z)
                let cell = try #require(sampler.cellOrigin(at: point))
                let expected: [UInt8] = valid.contains(cell.chunk)
                    ? (blue(cell.x, cell.y, cell.z) ? [0, 0, 255, 255] : [255, 0, 0, 255])
                    : [124, 189, 107, 255]
                #expect(parallel.color(point.x, point.z) == expected)
            } }
        }
        for z in 0..<32 { for x in 0..<32 where !valid.contains(.init(x: x, z: z)) {
            #expect(parallel.color(x * 16 + 8, z * 16 + 8) == [0, 0, 0, 0])
        } }
        await library.close()
    }

    @Test func sampledWaterFloorsAndUpperPlantsMatchExplicitPerBlockColors() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let sampler = BiomeSampler(seed: 0)
        let upper: NBT = .compound(["id": .string("minecraft:tall_grass"), "properties": .compound(["half": .string("upper")])])
        let palette: [NBT] = [.compound(["id": .string("minecraft:grass_block")]),
                              .compound(["id": .string("minecraft:water")]), upper,
                              .compound(["id": .string("minecraft:air")])]
        func blocks(_ x: Int, _ y: Int, _ z: Int) -> Int {
            if x < 8 { return y >= 12 ? 1 : 0 }
            return y > 12 ? 3 : y == 12 ? 2 : 0
        }
        func biome(_ x: Int, _ y: Int, _ z: Int) -> Int { ((x >> 2) ^ (y >> 2) ^ (z >> 2)) & 1 }
        func chunks(perBlock: Bool) -> [TestWorld.ChunkSpec] {
            (-1...1).flatMap { z in (-1...1).map { x in
                chunk(x: x, z: z, palette: palette, blocks: blocks, biomes: { localX, y, localZ in
                    let blockX = x * 16 + localX, blockZ = z * 16 + localZ
                    if !perBlock { return biome(blockX, y, blockZ) }
                    guard let cell = sampler.cellOrigin(at: .init(blockX: blockX, blockY: y, blockZ: blockZ)),
                          (0..<16).contains(cell.y), (-1...1).contains(cell.chunk.x), (-1...1).contains(cell.chunk.z)
                    else { return 2 }
                    return biome(cell.x, cell.y, cell.z)
                }, biomeIDs: ["test:a", "test:b", "test:missing"], biomeBits: 2, perBlock: perBlock)
            } }
        }
        let sampledURL = try world(chunks: chunks(perBlock: false), seed: 0)
        let explicitURL = try world(chunks: chunks(perBlock: true))
        defer { try? FileManager.default.removeItem(at: sampledURL); try? FileManager.default.removeItem(at: explicitURL) }
        let library = try fixture.library()
        func renderer(_ url: URL) async throws -> RegionTileRenderer {
            let world = try World(contentsOf: url)
            var value = RegionTileRenderer(dimension: try #require(world.dimension("overworld")), chunkConcurrency: 14)
            value.gameAssets = library; value.biomeColors = try await library.biomeColors(in: world)
            return value
        }
        var sampled = try await renderer(sampledURL), explicit = try await renderer(explicitURL)
        for blend in [false, true] { for style in [MapStyle.normal, .waterDepth] {
            sampled.blendsBiomeColors = blend; explicit.blendsBiomeColors = blend
            sampled.style = style; explicit.style = style
            let actual = try await pixels(sampled), expected = try await pixels(explicit)
            #expect(actual.bytes == expected.bytes)
        } }
        await library.close()
    }

    @Test func creatingChangingAndDeletingANeighborInvalidatesDiskTiles() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(chunks: [sampledChunk(.init(x: 0, z: 0), blue: { _, _, _ in false })], seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let library = try fixture.library(), region = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        let point = try westSample()
        let own = try #require(CacheKey.fileStamp(for: dimension.regionURL(at: region)))
        let neighbor = dimension.regionURL(at: .init(x: -1, z: 0))
        func color() async throws -> [UInt8] {
            try ItemPictureFixture.pixels(#require(try await renderer.tile(for: region)).full.image).color(point.x, point.z)
        }
        let missing = try await color()
        #expect(missing == [124, 189, 107, 255])
        for (blue, expected, stamp) in [(true, [0, 0, 255, 255], 1000.0), (false, [255, 0, 0, 255], 2000.0)] {
            try Data(TestWorld.regionFile([sampledChunk(.init(x: -1, z: 0), blue: { _, _, _ in blue })])).write(to: neighbor)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: neighbor.path)
            #expect(try await color() == expected.map(UInt8.init))
            #expect(try await color() == expected.map(UInt8.init)) // Stable dependencies reuse the current pixels.
        }
        try FileManager.default.removeItem(at: neighbor)
        #expect(try await color() == missing)
        let after = try #require(CacheKey.fileStamp(for: dimension.regionURL(at: region)))
        #expect(after.size == own.size && after.modified == own.modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count == 1)
        await library.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func neighborSaveCancelsTheOlderRenderAndOnlyTheReplacementPublishes(blending: Bool) async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        func terrain(_ x: Int, blue: Bool) -> TestWorld.ChunkSpec {
            if blending {
                return chunk(x: x, palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 },
                             biomes: { _, _, _ in blue ? 1 : 0 })
            }
            return sampledChunk(.init(x: x, z: 0), blue: { _, _, _ in blue })
        }
        let url = try world(chunks: [terrain(0, blue: false), terrain(-1, blue: false)], seed: blending ? nil : 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld")), library = try fixture.library()
        let gate = AsyncReadGate<Bool>(), reads = ReadNumbers(), work = BackgroundWork()
        let map = MapModel(work: work, dimension: dimension, center: CGPoint(x: 8, y: 8), regionConcurrency: 1,
            renderTile: { renderer, region in
                // Only hold the visible tile under test. Shadow-height neighbors can finish
                // normally without taking a gate intended for this tile's replacement.
                guard region == RegionPosition(x: 0, z: 0) else { return try await renderer.tile(for: region) }
                let name = String(await reads.next())
                let tile = try await renderer.tile(for: region)
                _ = await gate.read(name)
                return tile
            })
        map.setBiomeBlending(blending)
        map.setGameAssets(library, biomeColors: try await library.biomeColors(in: world))
        map.requestTiles(visibleIn: CGSize(width: 8, height: 8))
        await gate.waitForRequest("0")
        try Data(TestWorld.regionFile([terrain(-1, blue: true)]))
            .write(to: dimension.regionURL(at: .init(x: -1, z: 0)))
        map.regionsChanged([.init(x: -1, z: 0)])
        await gate.waitForCancellation("0")
        await gate.waitForRequest("1")
        await gate.finish("1", with: true)
        await map.waitUntilIdle()
        await gate.finish("0", with: true)
        await work.waitUntilFinished()
        let point = blending ? (x: 0, z: 8) : try westSample(), image = try #require(map.tiles[.init(x: 0, z: 0)]?.image)
        #expect(try ItemPictureFixture.pixels(image).color(point.x, point.z) == (blending ? [153, 0, 102, 255] : [0, 0, 255, 255]))
        map.close(); await work.waitUntilFinished(); await library.close()
    }

    @Test(.timeLimit(.minutes(1))) func savedGenerationSeedRefreshesSharedColorIdentityWithoutChangingLevelMetadata() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(seed: 0), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let session = WorldSession(resources: resources), library = try fixture.library()
        resources.refreshDelay = .zero
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation,
            version: GameAssetVersion(name: resources.world.level.versionName, dataVersion: resources.world.level.dataVersion))
        resources.prepareGameAssets(source); resources.setGameAssets(library, source: source)
        await resources.waitForRefresh()
        let original = try #require(session.map?.currentRenderer.biomeColors)
        let file = url.appendingPathComponent("data/minecraft/world_gen_settings.dat")
        try Fixtures.writeGzippedNBT(.compound(["data": .compound(["seed": .long(1)])]), to: file)
        resources.worldChanged([file])
        await resources.waitForRefresh()
        let changed = try #require(session.map?.currentRenderer.biomeColors)
        #expect(original.seed == 0 && changed.seed == 1 && original.sourceKey != changed.sourceKey)
        #expect(try !original.matchesMetadata(World(contentsOf: url), assetSourceKey: library.sourceKey))
        #expect(try changed.matchesMetadata(World(contentsOf: url), assetSourceKey: library.sourceKey))
        try Data([0]).write(to: file) // A transient unreadable source must retain the last good snapshot.
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(session.map?.currentRenderer.biomeColors?.sourceKey == changed.sourceKey)
        resources.close(); await resources.waitUntilClosed(); await library.close()
    }

    @Test func missingSeedDoesNotInventACellAndHeightDoesNotDependOnNeighbors() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(chunks: [sampledChunk(.init(x: 0, z: 0), blue: { _, _, _ in false })])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), library = try fixture.library()
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        #expect(renderer.biomeColors?.seed == nil && !renderer.samplesNeighborBiomes)
        #expect(try await pixels(renderer).color(8, 8) == [124, 189, 107, 255])
        try level(at: url, packs: ["vanilla"], seed: 0)
        renderer.biomeColors = try await library.biomeColors(in: World(contentsOf: url))
        #expect(renderer.samplesNeighborBiomes)
        renderer.style = .height
        #expect(!renderer.samplesNeighborBiomes)
        await library.close()
    }

    @Test func sampledCutawayClampsToSavedBuildHeightAndUsesThatRangeInTheDiskKey() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(chunks: [sampledChunk(.init(x: 0, z: 0), blue: { _, y, _ in y >= 16 })], seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld")), library = try fixture.library()
        let file = url.appendingPathComponent("data/minecraft/world_gen_settings.dat")
        func context(height: Int) throws -> MapSurfaceContext {
            let type: NBT = .compound(["min_y": .int(0), "height": .int(Int32(height)),
                                      "logical_height": .int(0), "has_ceiling": .byte(0)])
            try Fixtures.writeGzippedNBT(.compound(["data": .compound([
                "seed": .long(0), "dimensions": .compound(["minecraft:overworld": .compound(["type": type])])
            ])]), to: file)
            return MapSurfaceContext(dimensionID: dimension.id,
                settings: WorldDetails.read(try World(contentsOf: url)).dimensionSettings[dimension.id])
        }
        let cache = TileCache(directory: url.appendingPathComponent("tiles"))
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false, cutawayY: 15)
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        renderer.surfaceContext = try context(height: 32)
        #expect(renderer.surfaceContext.dimensionType?.maxY == 31)
        let tall = try ItemPictureFixture.pixels(#require(try await renderer.tile(for: .init(x: 0, z: 0))).full.image)
        renderer.surfaceContext = try context(height: 16)
        let short = try ItemPictureFixture.pixels(#require(try await renderer.tile(for: .init(x: 0, z: 0))).full.image)
        var crossed = 0
        for z in 2..<14 { for x in 2..<14 {
            let cell = try #require(BiomeSampler(seed: 0).cellOrigin(at: .init(blockX: x, blockY: 15, blockZ: z)))
            if cell.y == 16 {
                crossed += 1
                #expect(tall.color(x, z) == [0, 0, 255, 255] && short.color(x, z) == [255, 0, 0, 255])
            }
        } }
        #expect(crossed > 0)
        await library.close()
    }

    @Test func optionalBlendingSmoothsKnownBordersAndKeepsTheCenterWhenAnySampleIsMissing() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let spec = chunk(palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 },
                         biomes: { x, _, _ in x < 8 ? 0 : 1 })
        let url = try world(chunks: [spec])
        let missing = try world(chunks: [chunk(palette: [.string("minecraft:grass_block")],
            blocks: { _, _, _ in 0 }, biomes: { x, _, _ in x < 8 ? 0 : 1 }, biomeIDs: ["test:a", "test:missing"])])
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: missing) }
        let library = try fixture.library(), world = try World(contentsOf: url)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        let sharp = try await pixels(renderer)
        #expect(sharp.color(7, 8) == [255, 0, 0, 255] && sharp.color(8, 8) == [0, 0, 255, 255])
        renderer.blendsBiomeColors = true
        let blended = try await pixels(renderer)
        for (x, red, blue) in [(5, 255, 0), (6, 204, 51), (7, 153, 102), (8, 102, 153), (9, 51, 204), (10, 0, 255)] {
            #expect(blended.color(x, 8) == [UInt8(red), 0, UInt8(blue), 255])
        }
        #expect(blended.color(0, 8) == sharp.color(0, 8)) // The absent western chunk isn't invented.
        #expect(blended.color(7, 0) == sharp.color(7, 0)) // A partial north neighborhood keeps the center.
        var unavailable = RegionTileRenderer(dimension: try #require(try World(contentsOf: missing).dimension("overworld")))
        unavailable.gameAssets = library; unavailable.biomeColors = renderer.biomeColors
        unavailable.blendsBiomeColors = true
        let unknown = try await pixels(unavailable)
        #expect(unknown.color(7, 8) == [255, 0, 0, 255] && unknown.color(8, 8) == [124, 189, 107, 255])
        renderer.gameAssets = nil
        renderer.biomeColors = nil
        #expect(!renderer.samplesNeighborBiomes)
        let fallback = try await pixels(renderer)
        renderer.blendsBiomeColors = false
        #expect(try await pixels(renderer).bytes == fallback.bytes)
        await library.close()
    }

    @Test func blendedDisplacedCellsCrossNegativeChunkAndRegionBordersInSerialAndParallel() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let centers = [ChunkPosition(x: -32, z: -32), .init(x: 31, z: 31)]
        let positions = Set(centers.flatMap { center in (-1...1).flatMap { z in (-1...1).map { x in
            ChunkPosition(x: center.x + x, z: center.z + z)
        } } })
        func blue(_ x: Int, _ y: Int, _ z: Int) -> Bool { ((x >> 2) ^ (y >> 2) ^ (z >> 2)) & 1 == 1 }
        let url = try world(chunks: positions.map { sampledChunk($0, blue: blue) }, seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url), sampler = BiomeSampler(seed: 0)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")))
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        renderer.blendsBiomeColors = true
        for center in centers {
            renderer.chunkConcurrency = 1
            let serial = try ItemPictureFixture.pixels(#require(try await renderer.image(for: center.region)))
            renderer.chunkConcurrency = 14
            let parallel = try ItemPictureFixture.pixels(#require(try await renderer.image(for: center.region)))
            #expect(serial.bytes == parallel.bytes)
            let origin = try #require(center.blockOrigin)
            for z in 0..<16 { for x in 0..<16 {
                var blueCount = 0
                for dz in -2...2 { for dx in -2...2 {
                    let cell = try #require(sampler.cellOrigin(at: .init(blockX: origin.x + x + dx, blockY: 15, blockZ: origin.z + z + dz)))
                    if blue(cell.x, cell.y, cell.z) { blueCount += 1 }
                } }
                #expect(parallel.color(center.localX * 16 + x, center.localZ * 16 + z)
                    == [UInt8((25 - blueCount) * 255 / 25), 0, UInt8(blueCount * 255 / 25), 255])
            } }
        }
        await library.close()
    }

    @Test func blendingUsesEachNeighborsOwnPaletteLayout() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        func blue(_ x: Int, _ y: Int, _ z: Int) -> Bool { ((x >> 2) ^ (y >> 2) ^ (z >> 2)) & 1 == 1 }
        let center = ChunkPosition(x: 0, z: 0)
        let chunks = (-1...1).flatMap { z in (-1...1).map { x -> TestWorld.ChunkSpec in
            if x == 0 && z == 0 {
                return chunk(palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 },
                             biomes: { x, y, z in blue(x, y, z) ? 1 : 0 })
            }
            return sampledChunk(.init(x: x, z: z), blue: blue)
        } }
        let url = try world(chunks: chunks, seed: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try fixture.library(), world = try World(contentsOf: url), sampler = BiomeSampler(seed: 0)
        var renderer = RegionTileRenderer(dimension: try #require(world.dimension("overworld")), chunkConcurrency: 14)
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        renderer.blendsBiomeColors = true
        let image = try await pixels(renderer)
        var unavailableCenters = 0
        for z in [0, 7, 15] { for x in [0, 7, 15] {
            var count = 0, complete = true
            for dz in -2...2 { for dx in -2...2 {
                let point = BlockPosition(blockX: x + dx, blockY: 15, blockZ: z + dz)
                let selected = point.chunk == center ? point : try #require(sampler.cellOrigin(at: point))
                // A neighbor's displaced cell can point back into the center's missing
                // upper section. The fixture must not invent that absent palette.
                if selected.chunk == center && !(0..<16).contains(selected.y) { complete = false }
                if blue(selected.x, selected.y, selected.z) { count += 1 }
            } }
            let expected: [UInt8]
            if complete { expected = [UInt8((25 - count) * 255 / 25), 0, UInt8(count * 255 / 25), 255] }
            else {
                unavailableCenters += 1
                expected = blue(x, 15, z) ? [0, 0, 255, 255] : [255, 0, 0, 255]
            }
            #expect(image.color(x, z) == expected)
        } }
        #expect(unavailableCenters > 0)
        await library.close()
    }

    @Test func blendedPerBlockNeighborsWithoutASeedInvalidateDiskTilesAndKeepSharpCacheKeysSeparate() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        func solid(_ x: Int, blue: Bool) -> TestWorld.ChunkSpec {
            chunk(x: x, palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 }, biomes: { _, _, _ in blue ? 1 : 0 })
        }
        let url = try world(chunks: [solid(0, blue: false)])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld")), library = try fixture.library()
        let cache = TileCache(directory: url.appendingPathComponent("tiles")), region = RegionPosition(x: 0, z: 0)
        var renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        renderer.gameAssets = library; renderer.biomeColors = try await library.biomeColors(in: world)
        let sharpKey = renderer.colorSourceKey
        let sharp = try #require(try await renderer.tile(for: region))
        renderer.blendsBiomeColors = true
        #expect(renderer.colorSourceKey != sharpKey && renderer.samplesNeighborBiomes)
        let own = try #require(CacheKey.fileStamp(for: dimension.regionURL(at: region)))
        let neighbor = dimension.regionURL(at: .init(x: -1, z: 0))
        func color() async throws -> [UInt8] {
            try ItemPictureFixture.pixels(#require(try await renderer.tile(for: region)).full.image).color(0, 8)
        }
        #expect(try await color() == [255, 0, 0, 255])
        for (blue, expected, stamp) in [(true, [153, 0, 102, 255], 1000.0), (false, [255, 0, 0, 255], 2000.0)] {
            try Data(TestWorld.regionFile([solid(-1, blue: blue)])).write(to: neighbor)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: neighbor.path)
            #expect(try await color() == expected.map(UInt8.init))
            let hit = try #require(try await renderer.tile(for: region))
            #expect(hit.cacheWrite == nil)
            #expect(try ItemPictureFixture.pixels(hit.full.image).color(0, 8) == expected.map(UInt8.init))
        }
        try FileManager.default.removeItem(at: neighbor)
        #expect(try await color() == [255, 0, 0, 255])
        let after = try #require(CacheKey.fileStamp(for: dimension.regionURL(at: region)))
        #expect(after.size == own.size && after.modified == own.modified)
        renderer.blendsBiomeColors = false
        #expect(renderer.colorSourceKey == sharpKey)
        #expect(try ItemPictureFixture.pixels(#require(try await renderer.tile(for: region)).full.image).bytes == ItemPictureFixture.pixels(sharp.full.image).bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count == 1)
        await library.close()
    }

    @Test func blendedCurrentViewAndAreaExportsHaveIdenticalPixelsInBothAppearances() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let url = try world(chunks: [chunk(palette: [.string("minecraft:grass_block")], blocks: { _, _, _ in 0 },
                                          biomes: { x, _, _ in x < 8 ? 0 : 1 })])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld")), library = try fixture.library()
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero)
        map.setGameAssets(library, biomeColors: try await library.biomeColors(in: world))
        map.setBiomeBlending(true)
        let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 16, height: 16), blocksPerPixel: 1)
        map.viewport = plan.viewport
        map.requestTiles(visibleIn: plan.size, displayScale: 1)
        await map.waitUntilIdle()
        let tile = try ItemPictureFixture.pixels(#require(map.tiles[.init(x: 0, z: 0)]?.image))
        #expect(tile.color(7, 8) == [153, 0, 102, 255])
        func bytes(_ image: MapImage) throws -> Data {
            let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try #require(decoded.dataProvider?.data as Data?)
        }
        for appearance in [ColorScheme.light, .dark] {
            let area = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: map.currentRenderer,
                content: MapContent(), portalStatus: { _ in nil }, colorScheme: appearance, locale: Locale(identifier: "en_US"),
                progress: { _, _ in })
            let view = try #require(MapImage.render(map, content: MapContent(), portalStatus: { _ in nil }, size: plan.size,
                scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
            #expect(try bytes(area) == bytes(view))
        }
        map.close()
        await map.waitForRenders()
        await library.close()
    }

    private func westSample() throws -> (x: Int, z: Int) {
        let sampler = BiomeSampler(seed: 0)
        for x in 0...1 { for z in 4...11 {
            if sampler.cellOrigin(at: BlockPosition(blockX: x, blockY: 15, blockZ: z))?.chunk == ChunkPosition(x: -1, z: 0) {
                return (x, z)
            }
        } }
        throw NSError(domain: "Expected west-neighbor cell in the verified sampler", code: 1)
    }

    private func sampledChunk(_ position: ChunkPosition, blue: (Int, Int, Int) -> Bool) -> TestWorld.ChunkSpec {
        let origin = position.blockOrigin!
        let sections = (0...1).map { section in
            let cells = (0..<4).flatMap { y in (0..<4).flatMap { z in (0..<4).map { x in
                blue(origin.x + x * 4, section * 16 + y * 4, origin.z + z * 4) ? 1 : 0
            } } }
            return Fixtures.section(y: section, palette: [.string(section == 0 ? "minecraft:grass_block" : "minecraft:air")],
                                    biomes: ["test:a", "test:b"], biomeIndices: cells)
        }
        return .init(x: position.x, z: position.z, nbt: Fixtures.chunk(x: position.x, z: position.z, dataVersion: 5023, sections: sections, extra: ["yPos": .int(0)]))
    }

    private func pixels(_ renderer: RegionTileRenderer) async throws -> ItemPictureFixture.Pixels {
        try ItemPictureFixture.pixels(#require(try await renderer.image(for: .init(x: 0, z: 0))))
    }

    private func chunk(x: Int = 0, z: Int = 0, palette: [NBT], blocks: (Int, Int, Int) -> Int,
                       biomes: (Int, Int, Int) -> Int, biomeIDs: [String] = ["test:a", "test:b"], biomeBits: Int = 1, perBlock: Bool = true) -> TestWorld.ChunkSpec {
        func indices(_ read: (Int, Int, Int) -> Int) -> [Int] {
            (0..<16).flatMap { y in (0..<16).flatMap { z in (0..<16).map { x in read(x, y, z) } } }
        }
        // These tint/offset tests use synthetic per-block palettes; displaced-cell cases below
        // separately exercise the verified 26.3 four-block layout and neighboring data.
        let biomeCells = perBlock ? indices(biomes) : (0..<4).flatMap { y in (0..<4).flatMap { z in (0..<4).map { x in biomes(x * 4, y * 4, z * 4) } } }
        let section = Fixtures.section(y: 0, palette: palette, indices: indices(blocks),
            biomes: biomeIDs, biomeIndices: biomeCells, biomeBits: biomeBits)
        return .init(x: x, z: z, nbt: Fixtures.chunk(x: x, z: z, dataVersion: perBlock ? SaveVersion.perBlockBiomes : SaveVersion.java26_3, sections: [section], extra: ["yPos": .int(0)]))
    }

    private func world(chunks: [TestWorld.ChunkSpec] = [], seed: Int64? = nil) throws -> URL {
        let url = try TestWorld.make(chunks: chunks)
        try level(at: url, packs: ["vanilla"], seed: seed)
        return url
    }

    private func level(at url: URL, packs: [String], name: String = "Biome Map Check", seed: Int64? = nil) throws {
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string(name), "DataVersion": .int(5023),
            "Version": .compound(["Name": .string("26.3")]),
            "DataPacks": .compound(["Enabled": .list(packs.map(NBT.string))]),
            "WorldGenSettings": .compound(seed.map { ["seed": NBT.long($0)] } ?? [:])
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
