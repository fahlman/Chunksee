import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
import Synchronization
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldGameAssetsTests {
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
        await gate.waitForCancellation("on")
        await gate.waitForRequest("off")
        await gate.finish("off", with: withoutArtwork)
        await gate.finish("on", with: withArtwork)
        await resources.waitForRefresh()
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        #expect(resources.biomeColors?.sourceKey == withoutArtwork.sourceKey)
        resources.close()
        await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
    }

    @Test func artworkOffReadsDataAndRendersWithoutReadingAnyTexture() async throws {
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
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let session = WorldSession(resources: resources), source = WorldGameAssetSource(generation: names.minecraft.generation)
        resources.prepareGameAssets(source); resources.setGameAssets(library, source: source)
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

    @Test func firstSourcePreparationNotifiesAnAlreadyRenderedView() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        defer { resources.close() }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let observation = observe(resources, source: source)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        resources.prepareGameAssets(source)
        await expectUpdate(observation)
        resources.close()
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func asynchronousLoadAndJarReplacementPublishPicturesWithoutAnotherSceneEvent() async throws {
        let root = try TestWorld.make(chunks: []), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        defer { resources.close() }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        resources.prepareGameAssets(source)
        let loading = observe(resources, source: source)
        resources.refreshGameAssets()
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
        let firstLibrary = try #require(await resources.names.minecraft.library())
        let first = try #require(resources.gameArtworkLibrary(for: source))
        let removal = observe(resources, source: source)
        resources.names.minecraft.forget()
        await expectUpdate(removal)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        resources.setGameAssets(firstLibrary, source: source)
        #expect(resources.gameArtworkLibrary(for: source) == nil)
        await resources.waitForRefresh()
        await resources.names.minecraft.waitUntilIdle()
        #expect(try await first.picture(for: ItemStack(id: "test:flat")) == nil)

        resources.names.minecraft.choose(game.root)
        let current = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let rechoice = observe(resources, source: current)
        await resources.waitForRefresh()
        await expectUpdate(rechoice)
        let replacementLibrary = try #require(await resources.names.minecraft.library())
        let replacement = try #require(resources.gameArtworkLibrary(for: current))
        #expect(replacement !== first)
        resources.setGameAssets(firstLibrary, source: source)
        #expect(resources.gameArtworkLibrary(for: current) === replacement)
        let closing = observe(resources, source: current)
        resources.close()
        await expectUpdate(closing)
        resources.setGameAssets(replacementLibrary, source: current)
        #expect(resources.gameArtworkLibrary(for: current) == nil)
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }
}
