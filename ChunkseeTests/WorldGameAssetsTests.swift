import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
import Synchronization
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldGameAssetsTests {
    @Test func preparedAssetsSurviveOverlappingRefreshesAndPublishProgress() async throws {
        let game = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.choose(game.root)
        let gate = AsyncReadGate<GameResourceLibrary?>(), numbers = ReadNumbers()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { _ in await gate.read(String(await numbers.next())) })
        let first = WorldSession(resources: resources), hidden = WorldSession(resources: resources)
        var failure: (any Error)?
        do {
            let original = try #require(first.map?.currentRenderer.gameData)
            await resources.waitForRefresh()
            #expect(await gate.requested.isEmpty)
            let a = try game.resources(), b = try game.resources()
            resources.refreshGameAssets()
            await gate.waitForRequest("0")
            #expect(first.map?.currentRenderer.gameData === original)
            resources.refreshGameAssets(); resources.refreshGameAssets(); resources.refreshGameAssets()
            await gate.finish("0", with: a)
            await gate.waitForRequest("1")
            #expect(first.map?.currentRenderer.gameData === a.data && hidden.map?.currentRenderer.gameData === a.data)
            #expect(await gate.requested == ["0", "1"])
            first.close()
            #expect(!resources.isClosed)
            await gate.finish("1", with: b)
            await resources.waitForRefresh()
            #expect(hidden.map?.currentRenderer.gameData === b.data)
            #expect(await gate.requested == ["0", "1"])
        } catch { failure = error }
        await gate.releaseAllAndFuture(with: nil)
        resources.close(); await resources.waitUntilClosed()
        names.minecraft.forget(); await names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }

    @Test func unreadableInstalledDirectoryRetainsAssetsButSuccessfulRemovalClearsThem() async throws {
        let game = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        let session = WorldSession(resources: resources)
        var failure: (any Error)?
        do {
            await resources.waitForRefresh()
            let original = try #require(session.map?.currentRenderer.gameData), readers = resources.readers
            let definitions = resources.details.definitions
            let versions = game.root.appendingPathComponent("versions"), parked = game.root.appendingPathComponent("saved-versions")
            try FileManager.default.moveItem(at: versions, to: parked)
            try Data([0]).write(to: versions)
            do {
                _ = try await resources.names.minecraft.readLibrary()
                Issue.record("An unreadable versions directory must fail, not report successful absence")
            } catch { /* Expected file-read failure. */ }
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(session.map?.currentRenderer.gameData === original)
            #expect(resources.details.definitions == definitions)
            #expect(resources.readers["minecraft:overworld"] === readers["minecraft:overworld"])
            try FileManager.default.removeItem(at: versions)
            try FileManager.default.moveItem(at: parked, to: versions)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(session.map?.currentRenderer.gameData === original)
            try FileManager.default.removeItem(at: game.jar)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(session.map?.currentRenderer.gameData == nil && session.map?.currentRenderer.gameArtwork == nil)
            #expect(resources.details.definitions.enchantments["test:sample"] == nil)
            // A missing versions directory is also successful absence, not a retrying failure.
            try FileManager.default.removeItem(at: versions)
            let absent = try await resources.names.minecraft.readLibrary()
            #expect(absent == nil)
        } catch { failure = error }
        resources.close(); await resources.waitUntilClosed()
        resources.names.minecraft.forget(); await resources.names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }

    @Test func replacedAndClosedSourcesRejectDelayedAssetResults() async throws {
        let game = try artworkFixture(), replacement = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); replacement.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.choose(game.root)
        let gate = AsyncReadGate<GameResourceLibrary?>(), numbers = ReadNumbers()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { _ in await gate.read(String(await numbers.next())) })
        let first = WorldSession(resources: resources), hidden = WorldSession(resources: resources)
        var failure: (any Error)?
        do {
            await resources.waitForRefresh()
            let old = try game.resources(), current = try replacement.resources()
            resources.refreshGameAssets()
            await gate.waitForRequest("0")
            names.minecraft.choose(replacement.root)
            #expect(first.map?.currentRenderer.gameData == nil && hidden.map?.currentRenderer.gameData == nil)
            #expect(resources.gameNames.identity == GameNames.unavailable.identity && resources.newerWorldNotice == nil)
            await gate.waitForCancellation("0"); await gate.waitForRequest("1")
            await gate.finish("1", with: current)
            for await ready in Observations({ hidden.map?.currentRenderer.gameData === current.data }) where ready { break }
            await gate.finish("0", with: old)
            await resources.waitForRefresh()
            #expect(first.map?.currentRenderer.gameData === current.data && hidden.map?.currentRenderer.gameData === current.data)
            resources.refreshGameAssets()
            await gate.waitForRequest("2")
            resources.close()
            await gate.waitForCancellation("2")
            await gate.finish("2", with: old)
            await resources.waitUntilClosed()
            #expect(resources.mapGameResources.data == nil && first.map?.currentRenderer.gameData == nil)
        } catch { failure = error }
        await gate.releaseAllAndFuture(with: nil)
        resources.close(); await resources.waitUntilClosed()
        names.minecraft.forget(); await names.minecraft.waitUntilIdle()
        if let failure { throw failure }
    }

    @Test func artworkPreferenceDefaultsOnAndPersistsIndependentlyOfFolderAccess() async throws {
        let defaults = TestDefaults.make(), minecraft = MinecraftResources(defaults: defaults)
        let generation = minecraft.generation
        #expect(minecraft.usesGameArtwork && minecraft.folder == nil)
        minecraft.usesGameArtwork = false
        #expect(minecraft.generation == generation && minecraft.folder == nil)
        #expect(!MinecraftResources(defaults: defaults).usesGameArtwork)
        let game = try ItemPictureFixture()
        defer { game.remove() }
        minecraft.choose(game.root)
        let library = await minecraft.library()
        #expect(!minecraft.usesGameArtwork && library != nil)
        minecraft.forget()
        #expect(!minecraft.usesGameArtwork)
        minecraft.usesGameArtwork = true
        #expect(MinecraftResources(defaults: defaults).usesGameArtwork)
        await minecraft.waitUntilIdle()
    }

    @Test func artworkSwitchUpdatesEveryWorldAndRetainsDataAndCacheSeparation() async throws {
        let game = try artworkFixture()
        let firstRoot = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"], index: { _, _, _ in 0 })]),
            secondRoot = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"], index: { _, _, _ in 0 })])
        defer { game.remove(); try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: secondRoot) }
        let names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        func open(_ root: URL) async throws -> WorldResources {
            let defaults = TestDefaults.make()
            return try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        }
        let first = try await open(firstRoot), second = try await open(secondRoot)
        defer { first.close(); second.close() }
        let a = WorldSession(resources: first), hidden = WorldSession(resources: first), b = WorldSession(resources: second)
        first.refreshGameAssets(); second.refreshGameAssets()
        await first.waitForRefresh(); await second.waitForRefresh()
        let source = WorldGameAssetSource(generation: names.minecraft.generation)
        let library = try #require(first.gameArtworkLibrary(for: source))
        #expect(second.gameArtworkLibrary(for: source) === library)
        #expect(try await library.picture(for: ItemStack(id: "test:flat")) != nil)
        let definitions = first.details.definitions, readers = first.readers
        #expect(definitions.enchantments["test:sample"] != nil)
        first.readDefinitions = { _, _ in Issue.record("Artwork changes must not reload game definitions"); throw CancellationError() }
        let map = try #require(a.map)
        map.viewport = .init(center: CGPoint(x: 8, y: 8), scale: 8)
        map.requestTiles(visibleIn: CGSize(width: 64, height: 64), displayScale: 1)
        await map.waitForRenders()
        let original = try #require(map.tiles[.init(x: 0, z: 0)])
        let originalPixels = try ItemPictureFixture.pixels(original.image).bytes
        let artworkKey = try #require(map.currentRenderer.colorSourceKey)
        #expect(!map.detailImages.isEmpty)
        let observation = observe(first, source: source)

        names.minecraft.usesGameArtwork = false
        await expectUpdate(observation)
        for resources in [first, second] { #expect(resources.gameArtworkLibrary(for: source) == nil && resources.biomeColors?.source.artwork == .unavailable) }
        for session in [a, hidden, b] {
            #expect(session.map?.currentRenderer.gameArtwork == nil && session.map?.currentRenderer.gameData === library.data
                && session.map?.currentRenderer.biomeColors?.source.artwork == .unavailable)
        }
        #expect(map.detailImages.isEmpty && map.currentRenderer.gameSource.artwork == .unavailable)
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        let fallbackPixels = try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes
        #expect(fallbackPixels != originalPixels)
        #expect(first.details.definitions == definitions && first.readers["minecraft:overworld"] === readers["minecraft:overworld"])
        #expect(await names.minecraft.library()?.data === library.data && names.minecraft.generation == source.generation)
        #expect(first.biomeColors?.outlineColor(for: "test:sample", at: .zero) == MapColor(0x123456))

        names.minecraft.usesGameArtwork = true
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        #expect(first.gameArtworkLibrary(for: source) === library && second.gameArtworkLibrary(for: source) === library)
        #expect(map.currentRenderer.colorSourceKey == artworkKey && !map.detailImages.isEmpty)
        #expect(try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes == originalPixels)
        #expect(first.details.definitions == definitions)
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed(); await names.minecraft.waitUntilIdle()
    }

    @Test func delayedArtworkColorsCannotReturnAfterTheSwitchIsOff() async throws {
        let game = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        defer { resources.close() }
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let library = try #require(resources.gameArtworkLibrary(for: source))
        let withArtwork = try #require(resources.biomeColors)
        let withoutArtwork = try await library.data.biomeColors(in: resources.world, artwork: nil)
        #expect(withArtwork.outlineColor(for: "test:sample", at: .zero) != withoutArtwork.outlineColor(for: "test:sample", at: .zero))
        let gate = AsyncReadGate<MapBiomeColors>()
        resources.readBiomeColors = { _, _, artwork, _, _ in await gate.read(artwork == nil ? "off" : "on") }
        resources.refreshDelay = .zero
        resources.worldChanged([root.appendingPathComponent("datapacks/ChunkseeTest/data/test/worldgen/biome/sample.json")])
        await gate.waitForRequest("on")
        resources.names.minecraft.usesGameArtwork = false
        #expect(resources.biomeColors?.sourceKey == withoutArtwork.sourceKey)
        #expect(resources.biomeColors?.outlineColor(for: "test:sample", at: .zero)
            == withoutArtwork.outlineColor(for: "test:sample", at: .zero))
        await gate.waitForCancellation("on")
        await gate.waitForRequest("off")
        await gate.finish("off", with: withoutArtwork)
        await gate.finish("on", with: withArtwork)
        await resources.waitForRefresh()
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        #expect(resources.biomeColors?.sourceKey == withoutArtwork.sourceKey)
        resources.names.minecraft.usesGameArtwork = true
        #expect(resources.biomeColors?.sourceKey == withoutArtwork.sourceKey)
        await gate.waitForRequest("on", count: 2)
        await gate.finish("on", with: withArtwork)
        await resources.waitForRefresh()
        #expect(resources.biomeColors?.sourceKey == withArtwork.sourceKey)
        resources.close()
        await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
    }

    @Test func artworkOffReadsDataAndRendersWithoutReadingAnyTexture() async throws {
        let assetReads = TestGameAssets()
        let fixture = try artworkFixture()
        let section = Fixtures.section(y: 0, palette: [.string("minecraft:water")], biomes: ["test:sample"])
        let root = try TestWorld.make(chunks: [.init(x: 0, z: 0,
            nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3,
                                sections: [section], extra: ["yPos": .int(0)]))])
        defer { fixture.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.usesGameArtwork = false
        let reads = Mutex<[String]>([])
        let library = GameResourceLibrary(assets: try #require(try GameAssets(contentsOf: fixture.jar)), sourceKey: "fixture") { assets, id in
            reads.withLock { $0.append(id) }
            return assets.texture(id)
        }
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil }, readGameAssets: { try await assetReads.read($0) })
        defer { resources.close() }
        let session = WorldSession(resources: resources), source = WorldGameAssetSource(generation: names.minecraft.generation)
        await assetReads.publish(library, to: resources)
        await resources.waitForRefresh()
        let map = try #require(session.map), region = RegionPosition(x: 0, z: 0)
        let definitions = resources.details.definitions
        #expect(definitions.enchantments["test:sample"] != nil)
        #expect(map.currentRenderer.gameData === library.data)
        #expect(names.minecraft.artwork(for: library) == nil && resources.gameArtworkLibrary(for: source) == nil)
        #expect(try await library.data.mapMaterials(for: [.init("minecraft:stone")]).first?.model != nil)
        let colors = try #require(map.currentRenderer.biomeColors)
        #expect(colors.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
        func rendered() async throws -> RegionTileRenderer.RenderedTile {
            var renderer = map.currentRenderer
            renderer.cache = TileCache(directory: root.appendingPathComponent("artwork-test-cache"))
            return try #require(try await renderer.tile(for: region))
        }
        let off = try await rendered()
        #expect(off.detail == nil)
        let offKey = try #require(off.cacheWrite?.key)
        #expect(offKey.inputs.gameSource.artwork == .unavailable)
        #expect(reads.withLock { $0.isEmpty })

        names.minecraft.usesGameArtwork = true
        await resources.waitForRefresh()
        let artwork = try #require(resources.gameArtworkLibrary(for: source))
        #expect(try await artwork.picture(for: .init(id: "test:flat")) != nil)
        #expect(try await artwork.textureColor("test:item/red") != nil)
        let on = try await rendered(), onKey = try #require(on.cacheWrite?.key)
        #expect(on.heights == off.heights)
        #expect(on.cacheWrite?.surface.isWater == off.cacheWrite?.surface.isWater)
        #expect(onKey.inputs.gameSource.artwork == .game(library.sourceKey) && onKey != offKey)
        #expect(map.currentRenderer.biomeColors?.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
        #expect(!reads.withLock { $0.isEmpty })

        names.minecraft.usesGameArtwork = false
        let readsAtSwitch = reads.withLock { $0 }
        #expect(resources.biomeColors?.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
        await resources.waitForRefresh()
        let offAgain = try await rendered()
        #expect(offAgain.detail == nil && offAgain.heights == off.heights)
        #expect(try await library.data.definitions(in: resources.world) == definitions)
        #expect(offAgain.cacheWrite?.key == offKey)
        #expect(reads.withLock { $0 } == readsAtSwitch)
        resources.close(); await resources.waitUntilClosed()
    }

    private func artworkFixture() throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/blockstates/stone.json": ItemPictureFixture.json(["variants": ["": ["model": "test:item/cube"]]]),
            "assets/minecraft/textures/colormap/grass.png": ItemPictureFixture.png(Array(repeating: [UInt8(255), 0, 0, 255], count: 256 * 256).flatMap { $0 }, width: 256, height: 256),
            "data/test/worldgen/biome/sample.json": ItemPictureFixture.json(["temperature": 0.8, "downfall": 0.4, "effects": ["water_color": 0x123456]]),
            "data/test/enchantment/sample.json": ItemPictureFixture.json(["max_level": 2, "slots": ["head"], "effects": [String: String]()]),
        ])
    }

    private func resources(_ root: URL, game: ItemPictureFixture) async throws -> WorldResources {
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        return try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
    }

    private func observe(_ resources: WorldResources, source: WorldGameAssetSource) ->
        (updates: AsyncStream<Bool>, finish: @Sendable () -> Void) {
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        // This is the accessor used to inject pictures into the view environment.
        _ = withObservationTracking { resources.gameArtworkLibrary(for: source) } onChange: {
            continuation.yield(true)
        }
        return (updates, { continuation.finish() })
    }

    private func expectUpdate(_ observation: (updates: AsyncStream<Bool>, finish: @Sendable () -> Void)) async {
        // Call only after the owning operation finishes. A missing notification fails without
        // depending on a timer or accidentally waking for an unrelated later publication.
        observation.finish()
        var updates = observation.updates.makeAsyncIterator()
        #expect(await updates.next(isolation: #isolation) == true)
    }

    @Test func preparedOpeningExposesPicturesWithoutAnotherSceneEvent() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        defer { resources.close() }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let library = try #require(resources.gameArtworkLibrary(for: source))
        #expect(try await library.picture(for: ItemStack(id: "test:flat")) != nil)
        resources.refreshGameAssets()
        #expect(resources.gameArtworkLibrary(for: source) === library)
        resources.close()
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func mapsUseCurrentGameDataBeforeColorsFinishAndRejectRetiredColors() async throws {
        let assetReads = TestGameAssets()
        let root = try TestWorld.make(chunks: []), game = try artworkFixture(), replacementGame = try artworkFixture()
        defer { game.remove(); replacementGame.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { try await assetReads.read($0) })
        var sessions = [WorldSession(resources: resources), WorldSession(resources: resources)]
        let gate = AsyncReadGate<MapBiomeColors?>(), numbers = ReadNumbers()
        let replacement = try replacementGame.resources()
        let replacementArtwork = names.minecraft.artwork(for: replacement)
        func close() async {
            await gate.releaseAllAndFuture(with: nil)
            sessions.forEach { $0.close() }
            resources.close()
            await resources.waitUntilClosed()
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
            await replacementArtwork?.close()
            await replacement.data.close()
        }
        do {
            await resources.waitForRefresh()
            resources.readBiomeColors = { world, data, artwork, previous, reload in
                guard data != nil else {
                    return try await WorldResources.readBiomeColors(world, data: data, artwork: artwork,
                                                                   previous: previous, reload: reload)
                }
                guard let colors = await gate.read(String(await numbers.next())) else { throw CancellationError() }
                return colors
            }
            names.minecraft.choose(game.root)
            await gate.waitForRequest("0")
            let original = try #require(await names.minecraft.library())
            let originalArtwork = try #require(names.minecraft.artwork(for: original))
            let oldColors = try await original.data.biomeColors(in: resources.world, artwork: originalArtwork)
            sessions.append(WorldSession(resources: resources))
            for session in sessions {
                #expect(session.map?.currentRenderer.gameData === original.data)
                #expect(session.map?.currentRenderer.gameArtwork === originalArtwork)
                #expect(session.map?.currentRenderer.biomeColors == nil)
            }

            // A newly read archive under the same folder generation must be available before
            // its colors. A delayed read from the retired archive cannot reconnect it.
            await assetReads.publish(replacement, to: resources)
            for session in sessions {
                #expect(session.map?.currentRenderer.gameData === replacement.data)
                #expect(session.map?.currentRenderer.gameArtwork === replacementArtwork)
                #expect(session.map?.currentRenderer.biomeColors == nil)
            }
            await gate.waitForCancellation("0")
            await gate.waitForRequest("1")
            let current = try await replacement.data.biomeColors(in: resources.world, artwork: replacementArtwork)
            await gate.finish("1", with: current)
            await gate.finish("0", with: oldColors)
            await resources.waitForRefresh()
            for session in sessions {
                #expect(session.map?.currentRenderer.gameData === replacement.data)
                #expect(session.map?.currentRenderer.biomeColors?.sourceKey == current.sourceKey)
            }

            sessions[0].close()
            #expect(!resources.isClosed)
            names.minecraft.forget()
            for session in sessions {
                #expect(session.map?.currentRenderer.gameData == nil)
                #expect(session.map?.currentRenderer.gameArtwork == nil)
                #expect(session.map?.currentRenderer.biomeColors == nil)
            }
        } catch {
            await close()
            throw error
        }
        await close()
    }

    @Test func preparedMapReadsBlockInformationWithoutAFollowupResourcePush() async throws {
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        let game = try artworkFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        let session = WorldSession(resources: resources)
        func close() async {
            session.close()
            await session.waitUntilClosed()
            await resources.names.minecraft.waitUntilIdle()
        }
        do {
            let map = try #require(session.map)
            await resources.waitForRefresh()
            await map.waitForTopBlocks()
            let block = try #require(map.topBlock(at: map.viewport.center))
            #expect(block.id == "minecraft:stone" && block.hasGameDefinition == true)
        } catch {
            await close()
            throw error
        }
        await close()
    }

    @Test func asynchronousLoadAndJarReplacementPublishPicturesWithoutAnotherSceneEvent() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
        defer { resources.close() }
        // Choosing files after opening still publishes asynchronously to existing views.
        names.minecraft.choose(game.root)
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        let loading = observe(resources, source: source)
        await resources.waitForRefresh()
        await expectUpdate(loading)
        let first = try #require(resources.gameArtworkLibrary(for: source))
        let item = ItemStack(id: "test:flat")
        #expect(try await first.picture(for: item) != nil)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: game.jar.path)
        let replacing = observe(resources, source: source)
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        await expectUpdate(replacing)
        let replacement = try #require(resources.gameArtworkLibrary(for: source))
        #expect(replacement !== first)
        #expect(resources.names.minecraft.generation == source.generation)
        #expect(try await replacement.picture(for: item) != nil)
        resources.close()
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func removalRechoiceAndClosingRejectRetiredPictures() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        defer { resources.close() }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        let first = try #require(resources.gameArtworkLibrary(for: source))
        let removal = observe(resources, source: source)
        resources.names.minecraft.forget()
        await expectUpdate(removal)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        await resources.waitForRefresh()
        await resources.names.minecraft.waitUntilIdle()
        #expect(try await first.picture(for: ItemStack(id: "test:flat")) == nil)

        resources.names.minecraft.choose(game.root)
        let current = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let rechoice = observe(resources, source: current)
        await resources.waitForRefresh()
        await expectUpdate(rechoice)
        let replacement = try #require(resources.gameArtworkLibrary(for: current))
        #expect(replacement !== first)
        #expect(resources.gameArtworkLibrary(for: current) === replacement)
        let closing = observe(resources, source: current)
        resources.close()
        await expectUpdate(closing)
        #expect(resources.gameArtworkLibrary(for: current) == nil)
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }
}
