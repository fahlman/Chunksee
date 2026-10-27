import ChunkseeKit
import CoreGraphics
import Foundation
import Observation
import Testing
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
            return try WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
                savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        }
        let first = try await open(firstRoot), second = try await open(secondRoot)
        defer { first.close(); second.close() }
        let a = WorldSession(resources: first), hidden = WorldSession(resources: first), b = WorldSession(resources: second)
        first.refreshGameAssets(); second.refreshGameAssets()
        await first.waitForRefresh(); await second.waitForRefresh()
        let source = WorldGameAssetSource(generation: names.minecraft.generation)
        let library = try #require(first.gameAssetLibrary(for: source))
        #expect(second.gameAssetLibrary(for: source) === library)
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
        for resources in [first, second] { #expect(resources.gameAssetLibrary(for: source) == nil && resources.biomeColors == nil) }
        for session in [a, hidden, b] {
            #expect(session.map?.currentRenderer.gameAssets == nil && session.map?.currentRenderer.biomeColors == nil)
        }
        #expect(map.detailImages.isEmpty && map.currentRenderer.colorSourceKey == nil)
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        let fallbackPixels = try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes
        #expect(fallbackPixels != originalPixels)
        #expect(first.details.definitions == definitions && first.readers["minecraft:overworld"] === readers["minecraft:overworld"])
        #expect(await names.minecraft.library() === library && names.minecraft.generation == source.generation)
        #expect(first.biomeColors?.outlineColor(for: "test:sample", at: .zero) == MapColor(0x123456))

        names.minecraft.usesGameArtwork = true
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        #expect(first.gameAssetLibrary(for: source) === library && second.gameAssetLibrary(for: source) === library)
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
        let library = try #require(resources.gameAssetLibrary(for: source))
        let withArtwork = try #require(resources.biomeColors)
        let withoutArtwork = try await library.biomeColors(in: resources.world, usesArtwork: false)
        #expect(withArtwork.outlineColor(for: "test:sample", at: .zero) != withoutArtwork.outlineColor(for: "test:sample", at: .zero))
        let gate = AsyncReadGate<MapBiomeColors>()
        resources.readBiomeColors = { _, _, _, _, artwork in await gate.read(artwork ? "on" : "off") }
        resources.refreshDelay = .zero
        resources.worldChanged([root.appendingPathComponent("datapacks/ChunkseeTest/data/test/worldgen/biome/sample.json")])
        await gate.waitForRequest("on")
        resources.names.minecraft.usesGameArtwork = false
        await gate.waitForCancellation("on")
        await gate.waitForRequest("off")
        await gate.finish("off", with: withoutArtwork)
        await gate.finish("on", with: withArtwork)
        await resources.waitForRefresh()
        #expect(resources.gameAssetLibrary(for: source) == nil)
        #expect(resources.biomeColors?.sourceKey == withoutArtwork.sourceKey)
        resources.close()
        await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
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
        return try WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
    }

    private func observe(_ resources: WorldResources, source: WorldGameAssetSource) ->
        (updates: AsyncStream<Bool>, finish: @Sendable () -> Void) {
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        // This is the accessor used to inject pictures into the view environment.
        _ = withObservationTracking { resources.gameAssetLibrary(for: source) } onChange: {
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
        #expect(resources.gameAssetLibrary(for: source) == nil)
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
        let first = try #require(resources.gameAssetLibrary(for: source))
        let item = ItemStack(id: "test:flat")
        #expect(try await first.picture(for: item) != nil)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: game.jar.path)
        let replacing = observe(resources, source: source)
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        await expectUpdate(replacing)
        let replacement = try #require(resources.gameAssetLibrary(for: source))
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
        let first = try #require(resources.gameAssetLibrary(for: source))
        let removal = observe(resources, source: source)
        resources.names.minecraft.forget()
        await expectUpdate(removal)
        #expect(resources.gameAssetLibrary(for: source) == nil)
        resources.setGameAssets(first, source: source)
        #expect(resources.gameAssetLibrary(for: source) == nil)
        await resources.waitForRefresh()
        await resources.names.minecraft.waitUntilIdle()
        #expect(try await first.picture(for: ItemStack(id: "test:flat")) == nil)

        resources.names.minecraft.choose(game.root)
        let current = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let rechoice = observe(resources, source: current)
        await resources.waitForRefresh()
        await expectUpdate(rechoice)
        let replacement = try #require(resources.gameAssetLibrary(for: current))
        #expect(replacement !== first)
        resources.setGameAssets(first, source: source)
        #expect(resources.gameAssetLibrary(for: current) === replacement)
        let closing = observe(resources, source: current)
        resources.close()
        await expectUpdate(closing)
        resources.setGameAssets(replacement, source: current)
        #expect(resources.gameAssetLibrary(for: current) == nil)
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }
}
