import AppKit
import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSurfaceContextTests {
    @Test func viewContextFollowsSavedTypesAndGeneratorsInsteadOfDimensionNames() throws {
        let definitions: [String: NBT] = [
            "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether")),
            "minecraft:the_nether": TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld")),
            "example:offset": TestWorld.noiseDimension(type: ceilingType, noise: noise(minY: -64, height: 128)),
        ]
        let details = try details(definitions)
        let roof = MapSurfaceContext(settings: details.dimensionSettings["minecraft:overworld"], water: nil)
        #expect(roof.buildHeight == 256 && roof.ceilingY == 127 && roof.biomeSampleY == 64)
        let open = MapSurfaceContext(settings: details.dimensionSettings["minecraft:the_nether"], water: nil)
        #expect(open.buildHeight == 384 && open.ceilingY == nil && open.biomeSampleY == nil)
        let offset = MapSurfaceContext(settings: details.dimensionSettings["example:offset"], water: nil)
        #expect(offset.buildHeight == 256 && offset.ceilingY == 63 && offset.biomeSampleY == 0)
        let options = RegionReader.options(context: offset)
        #expect(options.height == 256 && options.biomeSampleY == 0)
    }

    @Test func unknownOrEmptyGenerationKeepsSurfaceWithAnyKnownBuildHeight() throws {
        let definitions: [String: NBT] = [
            "example:missing": .compound(["type": ceilingType]),
            "example:unknown": TestWorld.noiseDimension(type: ceilingType, noise: .string("example:unavailable")),
            "example:empty": TestWorld.noiseDimension(type: ceilingType, noise: noise(minY: 0, height: 0)),
            "minecraft:the_nether": TestWorld.noiseDimension(type: ceilingType, noise: noise(minY: 0, height: 0)),
            "example:flat": .compound(["type": ceilingType, "generator": .compound([
                "type": .string("minecraft:flat"), "settings": noise(minY: 0, height: 128),
            ])]),
            "example:no_type": TestWorld.noiseDimension(type: .string("example:unavailable"), noise: .string("minecraft:nether")),
        ]
        let details = try details(definitions)
        for id in definitions.keys {
            let context = MapSurfaceContext(settings: details.dimensionSettings[id], water: nil)
            #expect(context.ceilingY == nil && context.biomeSampleY == nil)
            #expect(context.buildHeight == (id == "example:no_type" ? nil : 256))
        }
        #expect(MapSurfaceContext.unknown.buildHeight == nil)
        #expect(RegionReader.options().biomeSampleY == nil && RegionReader.options().height == nil)
    }

    @Test func surfaceRuleHeightIsNotTheLogicalHeightOrAnIntersection() throws {
        let details = try details([
            "example:shifted": TestWorld.noiseDimension(type: ceilingType, noise: noise(minY: 64, height: 128)),
        ])
        let context = MapSurfaceContext(settings: details.dimensionSettings["example:shifted"], water: nil)
        // WorldGenerationContext uses max(minimums) and min(heights): 64..<192. Intersecting
        // build bounds instead would end at 128, while logical_height would supply only 64.
        #expect(context.ceilingY == 191 && context.biomeSampleY == 128 && context.buildHeight == 256)
    }

    @Test func unresolvedSettingsDoNotInventACeilingOrBuildBounds() throws {
        let unknown = MapSurfaceContext(settings: nil, water: nil)
        #expect(unknown.ceilingY == nil && unknown.biomeSampleY == nil && unknown.buildHeight == nil)
        let details = try details(["example:partial": .compound(["type": ceilingType])])
        let partial = MapSurfaceContext(settings: details.dimensionSettings["example:partial"], water: nil)
        #expect(partial.ceilingY == nil && partial.biomeSampleY == nil && partial.buildHeight == 256)
    }

    @Test func dimensionDocumentsShareContextAcrossTilesHoverCopyAndBiomeScans() async throws {
        let url = try roofWorld(definitions: [
            "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether")),
            "minecraft:the_nether": TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld")),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try await checkViews(url, expected: [
            ("minecraft:overworld", 48, "minecraft:stone", "minecraft:crimson_forest"),
            ("minecraft:the_nether", 127, "minecraft:bedrock", "minecraft:plains"),
        ])
    }

    @Test func unresolvedSavedSettingsUseTheActualSurfaceWithoutAGuessedRoof() async throws {
        let definitions = ["minecraft:the_nether": TestWorld.noiseDimension(
            type: .string("minecraft:the_nether"), noise: .string("minecraft:nether"))]
        // With no supplied jar or enabled fixture pack, references stay unavailable across
        // save versions. No dimension-name or version fallback invents a ceiling.
        let cases: [(Int32, [String]?)] = [
            (Int32(SaveVersion.java26_2), ["vanilla"]), (Int32(SaveVersion.java26_3 + 1), ["vanilla"]),
            (Int32(SaveVersion.java26_3), nil), (Int32(SaveVersion.java26_3), ["vanilla", "unresolved_experiment"]),
        ]
        for (version, packs) in cases {
            let url = try roofWorld(definitions: definitions)
            defer { try? FileManager.default.removeItem(at: url) }
            var level: [String: NBT] = ["LevelName": .string("Unresolved Nether"), "DataVersion": .int(version)]
            if let packs { level["DataPacks"] = .compound(["Enabled": .list(packs.map(NBT.string))]) }
            try Fixtures.writeGzippedNBT(.compound(["Data": .compound(level)]), to: url.appendingPathComponent("level.dat"))
            try Fixtures.writeGzippedNBT(.compound(["DataVersion": .int(version),
                "data": .compound(["dimensions": .compound(definitions)])]),
                to: url.appendingPathComponent("data/minecraft/world_gen_settings.dat"))
            let settings = WorldDetails.read(try World(contentsOf: url)).dimensionSettings["minecraft:the_nether"]
            #expect(settings?.type == nil && settings?.noiseGeneration == nil)
            try await checkViews(url, expected: [
                ("minecraft:the_nether", 127, "minecraft:bedrock", "minecraft:plains"),
                ("minecraft:overworld", 127, "minecraft:bedrock", "minecraft:plains"),
            ])
        }
    }

    @Test func surfaceCacheKeysIncludeHeightAndCeilingButCutawaysIgnoreBoth() async throws {
        let definitions = [
            "example:roof": TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether")),
            "example:lower_roof": TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: noise(minY: 0, height: 64)),
            "example:open": TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld")),
        ]
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0,
            palette: ["minecraft:air", "minecraft:stone", "minecraft:bedrock"]) { _, y, _ in
                y == 15 ? 2 : y == 2 ? 1 : 0
            }], dimensionSettings: definitions)
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), settings = WorldDetails.read(world).dimensionSettings
        let dimension = try #require(world.dimension("overworld")), region = RegionPosition(x: 0, z: 0)
        let file = dimension.regionURL(at: region)
        let contexts = [MapSurfaceContext.unknown] + definitions.keys.sorted().map { MapSurfaceContext(settings: settings[$0], water: nil) }
        let surfaceKeys = try contexts.map { try #require(TileCache.key(for: region, regionFile: file, context: $0)) }
        let sliceKeys = try contexts.map { try #require(TileCache.key(for: region, regionFile: file, context: $0, cutawayY: 2)) }
        #expect(Set(surfaceKeys).count == contexts.count)
        #expect(Set(sliceKeys).count == 1)

        let cache = TileCache(directory: url.appendingPathComponent("test-cache"))
        let roof = MapSurfaceContext(settings: settings["example:roof"], water: nil)
        let open = MapSurfaceContext(settings: settings["example:open"], water: nil)
        let roofKey = try #require(TileCache.key(for: region, regionFile: file, context: roof))
        let openKey = try #require(TileCache.key(for: region, regionFile: file, context: open))
        let roofTile = try #require(try await RegionTileRenderer(dimension: dimension, surfaceContext: roof,
            cache: cache, savesInBackground: false).tile(for: region))
        #expect(cache.load(roofKey) != nil && cache.load(openKey) == nil)
        let openTile = try #require(try await RegionTileRenderer(dimension: dimension, surfaceContext: open,
            cache: cache, savesInBackground: false).tile(for: region))
        #expect(roofTile.full.image.dataProvider?.data as Data? != openTile.full.image.dataProvider?.data as Data?)
        #expect(cache.load(roofKey) == nil && cache.load(openKey) != nil)
    }

    @Test func knownTallBuildHeightReachesTheSharedHeightmapReader() throws {
        let type = NBT.compound(["min_y": .int(-1040), "height": .int(3072),
            "logical_height": .int(3072), "has_ceiling": .byte(0)])
        // 12-bit heightmaps share a packed length with 11-bit ones. The saved first-free Y is 8,
        // deliberately below the stored section top, so falling back to blocks would return 15.
        let chunk = TestWorld.ChunkSpec(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: SaveVersion.java26_3, sections: [Fixtures.section(y: 0, palette: [.string("minecraft:stone")])],
            extra: ["yPos": .int(-65), "Heightmaps": .compound([
                "WORLD_SURFACE": .longArray(Fixtures.pack(Array(repeating: 1048, count: 256), bits: 12)),
            ])]))
        let url = try TestWorld.make(chunks: [chunk], dimensionSettings: ["minecraft:overworld": .compound(["type": type])])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), dimension = try #require(world.dimension("overworld"))
        let context = MapSurfaceContext(settings: WorldDetails.read(world).dimensionSettings[dimension.id], water: nil)
        #expect(context.buildHeight == 3072)
        let file = try #require(try dimension.region(x: 0, z: 0))
        let known = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, context: context))
        let unknown = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(known.allSatisfy { $0?.y == 7 })
        #expect(unknown.allSatisfy { $0?.y == 15 })
    }

    private func roofWorld(definitions: [String: NBT]) throws -> URL {
        let sections = (0..<8).map { section in
            Fixtures.section(y: section, palette: [.string("minecraft:air"), .string("minecraft:stone"), .string("minecraft:bedrock")],
                indices: (0..<4096).map { index in
                    let y = section * 16 + index / 256
                    return y >= 126 ? 2 : y == 48 ? 1 : 0
                }, biomes: [section == 4 ? "minecraft:crimson_forest" : "minecraft:plains"])
        }
        let chunk = TestWorld.ChunkSpec(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: SaveVersion.java26_3, sections: sections, extra: ["yPos": .int(0)]))
        let url = try TestWorld.make(chunks: [chunk], dimensionSettings: definitions)
        let nether = url.appendingPathComponent("DIM-1/region")
        try FileManager.default.createDirectory(at: nether, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url.appendingPathComponent("dimensions/minecraft/overworld/region/r.0.0.mca"),
                                        to: nether.appendingPathComponent("r.0.0.mca"))
        return url
    }

    @Test(.timeLimit(.minutes(1))) func savedDefinitionChangesReachAnExistingMapThroughObservation() async throws {
        let id = "minecraft:overworld"
        let open = TestWorld.noiseDimension(type: .string("minecraft:overworld"), noise: .string("minecraft:overworld"))
        let roof = TestWorld.noiseDimension(type: .string("minecraft:the_nether"), noise: .string("minecraft:nether"))
        let root = try roofWorld(definitions: [id: open])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let session = WorldSession(resources: resources, dimensionID: id)
        defer { session.close() }
        resources.refreshDelay = .zero
        let map = try #require(session.map), reader = try #require(resources.readers[id])
        let point = CGPoint(x: 8, y: 8)
        map.loadTopBlocks(at: point)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: point)?.y == 127 && map.heightScale?.bounds == -64...319)
        map.setStyle(.height)
        let metadata = root.appendingPathComponent("data/minecraft/world_gen_settings.dat")
        try Fixtures.writeGzippedNBT(.compound(["DataVersion": .int(Int32(SaveVersion.java26_3)),
            "data": .compound(["dimensions": .compound([id: roof])])]), to: metadata)
        resources.worldChanged([metadata])
        await resources.waitForRefresh()
        #expect(session.map === map && map.heightScale?.bounds == 0...255 && map.style == .height)
        #expect(resources.readers[id] !== reader)
        map.loadTopBlocks(at: point)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: point)?.y == 48)
        let facts = try #require(await resources.readers[id]?.facts(.init(x: 0, z: 0)))
        #expect(facts.chunks.first?.sampledBiome == "minecraft:crimson_forest")
        session.close(); await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1))) func choosingGameFilesWithUnchangedDimensionFactsKeepsTheChosenHeightStyle() async throws {
        let root = try roofWorld(definitions: ["minecraft:overworld": TestWorld.noiseDimension(
            type: .string("minecraft:overworld"), noise: .string("minecraft:overworld"))])
        let game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let session = WorldSession(resources: resources)
        defer { session.close() }
        let map = try #require(session.map), scale = try #require(map.heightScale)
        map.setStyle(.height)
        resources.names.minecraft.choose(game.root)
        await resources.waitForRefresh()
        #expect(map.heightScale == scale && map.style == .height)
        session.close(); await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test(.timeLimit(.minutes(1))) func pendingGameSelectionKeepsHeightUntilItsDefinitionsAreKnown() async throws {
        enum ReadFailure: Error { case unavailable }
        let id = "minecraft:overworld"
        let root = try roofWorld(definitions: [id: TestWorld.noiseDimension(
            type: .string("example:game_height"), noise: .string("example:game_height"))])
        let game = try ItemPictureFixture(extraFiles: [
            "data/example/dimension_type/game_height.json": Data(
                #"{"min_y":-64,"height":384,"logical_height":384,"has_ceiling":false,"has_skylight":true}"#.utf8),
            "data/example/worldgen/noise_settings/game_height.json": Data(
                #"{"noise":{"min_y":-64,"height":384},"sea_level":63}"#.utf8),
        ])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.choose(game.root)
        let gate = AsyncReadGate<Result<GameResourceLibrary?, any Error>>()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { _ in try await gate.read("selection").get() })
        let session = WorldSession(resources: resources)
        var failure: (any Error)?
        do {
            await resources.waitForRefresh()
            let map = try #require(session.map), scale = try #require(map.heightScale)
            let definitions = resources.details.definitions, players = resources.playerSnapshot
            let reader = try #require(resources.readers[id]), generation = names.minecraft.generation
            map.setStyle(.height)

            // Settings uses this same source change. Failed discovery leaves the replacement
            // unread; it must not publish a successful no-game definition read in the meantime.
            await names.chooseMinecraftFolder(game.root)
            await gate.waitForRequest("selection")
            await gate.finish("selection", with: .failure(ReadFailure.unavailable))
            await resources.waitForRefresh()
            #expect(names.minecraft.generation != generation)
            #expect(resources.details.definitions == definitions && resources.playerSnapshot === players)
            #expect(resources.readers[id] === reader)
            #expect(map.heightScale == scale && map.style == .height)

            let library = try #require(try await names.minecraft.readLibrary())
            resources.refreshGameAssets()
            await gate.waitForRequest("selection", count: 2)
            await gate.finish("selection", with: .success(library))
            await resources.waitForRefresh()
            #expect(resources.mapGameResources.data === library.data)
            #expect(map.heightScale == scale && map.style == .height)
            #expect(resources.readers[id] === reader)

            // A completed absence is different: the game-only scale really is unavailable.
            names.forgetMinecraftFolder()
            await gate.waitForRequest("selection", count: 3)
            await gate.finish("selection", with: .success(nil))
            await resources.waitForRefresh()
            #expect(map.heightScale == nil && map.style == .normal)
        } catch { failure = error }
        await gate.releaseAllAndFuture(with: .success(nil))
        session.close(); resources.close(); await resources.waitUntilClosed()
        names.forgetMinecraftFolder(); await names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }

    private func checkViews(_ url: URL, expected: [(String, Int, String, String)]) async throws {
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        var sessions: [WorldSession] = []
        func close() async {
            sessions.forEach { $0.close() }
            resources.close()
            for session in sessions { await session.waitUntilClosed() }
            await resources.waitUntilClosed()
        }
        do {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for (id, y, block, biome) in expected {
                let session = WorldSession(resources: resources, dimensionID: id)
                sessions.append(session)
                let map = try #require(session.map), reader = try #require(resources.readers[id])
                map.viewport.center = CGPoint(x: 8, y: 8)
                map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
                await map.waitUntilIdle()
                let pixels = try #require(map.tiles[.init(x: 0, z: 0)]?.image.dataProvider?.data as Data?)
                let color = try #require(BlockColors.color(for: block)), offset = (8 * 512 + 8) * 4
                #expect(Array(pixels[offset ..< offset + 4]) == [color.red, color.green, color.blue, 255])

                // Copy before hover to exercise the separate on-demand read with the same renderer.
                MapClipboard.copy(CGPoint(x: 8, y: 8), on: map, to: board)
                await map.waitForCoordinateReads()
                #expect(board.string(forType: .string) == "8 \(y) 8")
                map.loadTopBlocks(at: CGPoint(x: 8, y: 8))
                await map.waitForTopBlocks()
                #expect(map.topBlock(at: CGPoint(x: 8, y: 8)) == .init(id: block, y: y, waterDepth: 0))
                let facts = try #require(await reader.facts(.init(x: 0, z: 0)))
                #expect(facts.chunks.first?.sampledBiome == biome)

                map.setDepth(MapDepth(y: 127, isSurface: false))
                MapClipboard.copy(CGPoint(x: 8, y: 8), on: map, to: board)
                await map.waitForCoordinateReads()
                #expect(board.string(forType: .string) == "8 127 8")
            }
        } catch { await close(); throw error }
        await close()
    }

    private var ceilingType: NBT {
        .compound(["min_y": .int(-128), "height": .int(256), "logical_height": .int(64), "has_ceiling": .byte(1)])
    }

    private func noise(minY: Int32, height: Int32) -> NBT {
        .compound(["noise": .compound(["min_y": .int(minY), "height": .int(height)])])
    }

    private func details(_ definitions: [String: NBT]) throws -> WorldDetails {
        let url = try TestWorld.make(chunks: [], dimensionSettings: definitions)
        defer { try? FileManager.default.removeItem(at: url) }
        return WorldDetails.read(try World(contentsOf: url))
    }
}
