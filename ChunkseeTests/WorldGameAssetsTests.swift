import ChunkseeKit
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldGameAssetsTests {
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
