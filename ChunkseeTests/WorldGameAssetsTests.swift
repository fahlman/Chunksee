import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
import Synchronization
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldGameAssetsTests {
    private enum PreparationResult: CaseIterable { case colors, colorFailure, noGame, gameFailure }

    @Test(arguments: PreparationResult.allCases)
    private func colorJobsWaitForGameSelectionAndColorsThenDrainWithoutMoving(result: PreparationResult) async throws {
        let game = try artworkFixture()
        let section = Fixtures.section(y: 0, palette: [.string("minecraft:water")], biomes: ["test:sample"])
        let root = try TestWorld.make(chunks: [.init(x: 0, z: 0,
            nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3,
                                sections: [section], extra: ["yPos": .int(0)]))],
            dimensionSettings: ["minecraft:overworld": TestWorld.noiseDimension(
                type: .string("minecraft:overworld"),
                noise: .compound(["noise": .compound(["min_y": .int(-64), "height": .int(384)]),
                                  "sea_level": .int(63)]))])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let snapshot = try await WorldSnapshot.read(root)
        let dimension = try #require(snapshot.world.dimension("overworld"))
        let heightScale = try #require(MapHeightScale(settings: snapshot.details.dimensionSettings[dimension.id]))
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.usesGameArtwork = false
        let library = try game.resources()
        let assets = AsyncReadGate<Result<GameResourceLibrary?, CocoaError>>()
        let colors = AsyncReadGate<Result<MapBiomeColors, CocoaError>>()
        let resources = try await WorldResources(snapshot: snapshot, names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { _ in try await assets.read("selection").get() })
        let drawings = Mutex<[MapGameResources.Identity]>([]), heightDrawings = Mutex(0), closingDrawings = Mutex(0)
        let map = MapModel(definitions: { .unknown }, gameResources: { resources.mapGameResources },
            savedLighting: { nil }, nightLighting: { nil }, work: resources.backgroundWork,
            dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, region in
                drawings.withLock { $0.append(MapGameResources(colorsReady: true, data: renderer.gameData,
                    artwork: renderer.gameArtwork, biomeColors: renderer.biomeColors).identity) }
                return try await renderer.tile(for: region)
            })
        let height = MapModel(definitions: { .init(context: .unknown, heightScale: heightScale) },
            gameResources: { resources.mapGameResources }, savedLighting: { nil }, nightLighting: { nil },
            work: resources.backgroundWork, dimension: dimension, center: CGPoint(x: 8, y: 8),
            renderTile: { renderer, region in
                heightDrawings.withLock { $0 += 1 }
                return try await renderer.tile(for: region)
            })
        var failure: (any Error)?
        var idleWait: Task<Void, Never>?
        do {
            await resources.waitForRefresh()
            resources.readBiomeColors = { world, data, artwork, previous, reload in
                guard data != nil else {
                    return try await WorldResources.readBiomeColors(world, data: data, artwork: artwork,
                                                                   previous: previous, reload: reload)
                }
                return try await colors.read("colors").get()
            }
            names.minecraft.choose(game.root)
            await assets.waitForRequest("selection")
            let size = CGSize(width: 1, height: 1), viewport = map.viewport
            map.requestTiles(visibleIn: size, displayScale: 1)
            #expect(!resources.mapGameResources.colorsReady && map.isLoading)
            #expect(drawings.withLock { $0.isEmpty })
            var idle = false
            let waiting = Task.immediate { await map.waitUntilIdle(); idle = true }
            idleWait = waiting
            #expect(!idle)
            // Height has no material-color input and must remain usable during the same wait.
            height.setStyle(.height)
            height.requestTiles(visibleIn: size, displayScale: 1)
            await height.waitUntilIdle(); await height.waitForRenders()
            #expect(height.style == .height && heightDrawings.withLock { $0 } == 1)
            #expect(map.isLoading && !idle && drawings.withLock { $0.isEmpty })

            switch result {
            case .gameFailure:
                await assets.finish("selection", with: .failure(CocoaError(.fileReadUnknown)))
            case .noGame:
                await assets.finish("selection", with: .success(nil))
            case .colors, .colorFailure:
                await assets.finish("selection", with: .success(library))
                await colors.waitForRequest("colors")
                #expect(resources.mapGameResources.data === library.data)
                #expect(!resources.mapGameResources.colorsReady && map.isLoading && !idle)
                #expect(drawings.withLock { $0.isEmpty })
                if result == .colors {
                    let matching = try await library.data.biomeColors(in: resources.world, artwork: nil)
                    await colors.finish("colors", with: .success(matching))
                } else {
                    await colors.finish("colors", with: .failure(CocoaError(.fileReadUnknown)))
                }
            }
            await resources.waitForRefresh()
            await waiting.value; await map.waitForRenders()
            #expect(resources.mapGameResources.colorsReady && idle && !map.isLoading)
            #expect(map.viewport == viewport && drawings.withLock { $0.count } == 1)
            #expect(heightDrawings.withLock { $0 } == 1)
            let region = RegionPosition(x: 0, z: 0)
            let actual = try #require(map.tiles[region])
            let renderer = try #require(map.currentRenderer)
            let expected = try #require(try await renderer.tile(for: region))
            #expect(actual.key == expected.key)
            #expect(actual.picture.image.dataProvider?.data as Data? == expected.full.image.dataProvider?.data as Data?)
            #expect((renderer.biomeColors != nil) == (result != .colorFailure))

            if result == .colorFailure {
                // An autosave retries the failed color read, but its pending state must not
                // erase an already accepted fallback picture or redraw unchanged inputs.
                resources.refreshDelay = .zero
                resources.worldChanged([root.appendingPathComponent("level.dat")])
                await colors.waitForRequest("colors", count: 2)
                #expect(!resources.mapGameResources.colorsReady)
                #expect(map.tiles[region]?.image === actual.image)
                #expect(!map.isLoading && map.viewport == viewport)
                #expect(drawings.withLock { $0.count } == 1)
                await colors.finish("colors", with: .failure(CocoaError(.fileReadUnknown)))
                await resources.waitForRefresh()
                await map.waitUntilIdle(); await map.waitForRenders()
                #expect(resources.mapGameResources.colorsReady)
                #expect(map.tiles[region]?.image === actual.image)
                #expect(!map.isLoading && map.viewport == viewport)
                #expect(drawings.withLock { $0.count } == 1)
                #expect(heightDrawings.withLock { $0 } == 1)
            }

            names.minecraft.choose(game.root)
            #expect(!resources.mapGameResources.colorsReady && map.isLoading)
            map.close()
            await map.waitUntilIdle()
            #expect(!map.isLoading && drawings.withLock { $0.count } == 1)
            let closingSession = WorldSession(resources: resources, renderTile: { _, _ in
                closingDrawings.withLock { $0 += 1 }
                return nil
            })
            let closingMap = try #require(closingSession.map)
            closingMap.viewport.center = CGPoint(x: 8, y: 8)
            closingMap.requestTiles(visibleIn: size, displayScale: 1)
            #expect(closingMap.isLoading)
            resources.close()
            #expect(closingSession.isClosed && !closingMap.isLoading)
            #expect(!resources.mapGameResources.colorsReady)
        } catch { failure = error }
        map.close(); height.close(); resources.close()
        await idleWait?.value
        await assets.releaseAllAndFuture(with: .failure(CocoaError(.fileReadUnknown)))
        await colors.releaseAllAndFuture(with: .failure(CocoaError(.fileReadUnknown)))
        await resources.waitUntilClosed()
        #expect(closingDrawings.withLock { $0 } == 0)
        names.minecraft.forget(); await names.minecraft.waitUntilIdle()
        await library.data.close()
        if let failure { throw failure }
    }

    @Test func folderObservationSeesOnlyTheCompletedChoiceAndItsPermission() async throws {
        let first = try ItemPictureFixture(), second = try ItemPictureFixture()
        defer { first.remove(); second.remove() }
        let defaults = TestDefaults.make(), minecraft = MinecraftResources(defaults: defaults)
        minecraft.usesGameArtwork = false
        let folders: [URL?] = [first.root, second.root, nil, first.root]
        for folder in folders {
            let previous = minecraft.generation
            let delivered = Mutex<(UUID, URL?, URL?)?>(nil)
            withObservationTracking(options: [.didSet]) {
                _ = minecraft.generation
                _ = minecraft.folder
                _ = minecraft.access
            } onChange: { event in
                event.cancel()
                MainActor.assumeIsolated {
                    delivered.withLock { $0 = (minecraft.generation, minecraft.folder, minecraft.access?.url) }
                }
            }
            if let folder { minecraft.choose(folder) } else { minecraft.forget() }
            let publication = try #require(delivered.withLock { $0 })
            #expect(publication.0 != previous && publication.0 == minecraft.generation)
            #expect(publication.1 == folder && publication.2 == folder)
            #expect(!minecraft.usesGameArtwork)
            let restored = MinecraftResources(defaults: defaults)
            #expect(restored.folder?.standardizedFileURL == folder?.standardizedFileURL)
            #expect(!restored.usesGameArtwork)
            #expect((try await minecraft.readLibrary() != nil) == (folder != nil))
        }
        minecraft.forget(); await minecraft.waitUntilIdle()
    }

    @Test func sourceChangesDoNotMultiplyMapRenderRequests() async throws {
        let game = try artworkFixture()
        let section = Fixtures.section(y: 0, palette: [.string("minecraft:stone")], biomes: ["test:sample"])
        let root = try TestWorld.make(chunks: [.init(x: 0, z: 0,
            nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3,
                                sections: [section], extra: ["yPos": .int(0)]))])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(World(contentsOf: root).dimension("overworld"))
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        names.minecraft.choose(game.root)
        let assetReads = Mutex<[UUID]>([])
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { minecraft in
                let generation = await minecraft.generation
                assetReads.withLock { $0.append(generation) }
                return try await minecraft.readLibrary()
            })
        let session = WorldSession(resources: resources), hidden = WorldSession(resources: resources)
        await resources.waitForRefresh()
        let drawings = Mutex<[MapGameResources.Identity]>([])
        let map = MapModel(definitions: { .unknown }, gameResources: { resources.mapGameResources }, savedLighting: { nil }, nightLighting: { nil },
            work: resources.backgroundWork, dimension: dimension, center: CGPoint(x: 8, y: 8), renderTile: { renderer, region in
                let identity = MapGameResources(colorsReady: true, data: renderer.gameData, artwork: renderer.gameArtwork,
                                                biomeColors: renderer.biomeColors).identity
                drawings.withLock { $0.append(identity) }
                return try await renderer.tile(for: region)
            })
        map.viewport.scale = 1
        map.requestTiles(visibleIn: CGSize(width: 1, height: 1), displayScale: 1)
        await map.waitUntilIdle(); await map.waitForRenders()
        for _ in 0..<3 {
            for available in [false, true] {
                drawings.withLock { $0.removeAll() }
                assetReads.withLock { $0.removeAll() }
                if available { resources.names.minecraft.choose(game.root) }
                else { resources.names.minecraft.forget() }
                await resources.waitForRefresh()
                await resources.backgroundWork.waitUntilFinished()
                await map.waitUntilIdle(); await map.waitForRenders()
                let actual = drawings.withLock { $0 }
                #expect(assetReads.withLock { $0 } == [names.minecraft.generation])
                let distinct = actual.reduce(into: [MapGameResources.Identity]()) { values, value in
                    if !values.contains(value) { values.append(value) }
                }
                #expect(!actual.isEmpty)
                #expect(actual.count == distinct.count,
                        "One source transition must not restart the same map drawing through duplicate observers")
                #expect(try (requiredRenderer(map).gameData != nil) == available)
                #expect(try requiredRenderer(session.map).gameData === requiredRenderer(hidden.map).gameData)
            }
        }
        map.close(); session.close(); hidden.close(); resources.close()
        await resources.waitUntilClosed()
        resources.names.minecraft.forget(); await resources.names.minecraft.waitUntilIdle()
    }

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
            let original = try #require((try requiredRenderer(first.map)).gameData)
            await resources.waitForRefresh()
            #expect(await gate.requested.isEmpty)
            let a = try game.resources(), b = try game.resources()
            resources.refreshGameAssets()
            await gate.waitForRequest("0")
            #expect(try requiredRenderer(first.map).gameData === original)
            resources.refreshGameAssets(); resources.refreshGameAssets(); resources.refreshGameAssets()
            await gate.finish("0", with: a)
            await gate.waitForRequest("1")
            #expect(try requiredRenderer(first.map).gameData === a.data && requiredRenderer(hidden.map).gameData === a.data)
            #expect(await gate.requested == ["0", "1"])
            first.close()
            #expect(!resources.isClosed)
            await gate.finish("1", with: b)
            await resources.waitForRefresh()
            #expect(try requiredRenderer(hidden.map).gameData === b.data)
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
            let original = try #require((try requiredRenderer(session.map)).gameData), readers = resources.readers
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
            #expect(try requiredRenderer(session.map).gameData === original)
            #expect(resources.details.definitions == definitions)
            #expect(resources.readers["minecraft:overworld"] === readers["minecraft:overworld"])
            try FileManager.default.removeItem(at: versions)
            try FileManager.default.moveItem(at: parked, to: versions)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(try requiredRenderer(session.map).gameData === original)
            try FileManager.default.removeItem(at: game.jar)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(try requiredRenderer(session.map).gameData == nil && requiredRenderer(session.map).gameArtwork == nil)
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

    @Test(arguments: [false, true])
    func restoredUnchangedArchiveRecoversBiomeColors(artwork: Bool) async throws {
        let game = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        resources.names.minecraft.usesGameArtwork = artwork
        let visible = WorldSession(resources: resources), hidden = WorldSession(resources: resources)
        var failure: (any Error)?
        do {
            await resources.waitForRefresh()
            // Keep the old handle alive so recovery cannot depend on weak-cache eviction.
            let original = try #require(await resources.names.minecraft.library())
            let colors = try #require(resources.biomeColors)
            let stamp = try #require(CacheKey.fileStamp(for: game.jar))
            let generation = resources.names.minecraft.generation
            #expect(colors.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
            #expect(colors.biome("test:sample").color(.grass, x: 0, z: 0) == (artwork ? 0xff0000 : nil))

            let parked = game.root.appendingPathComponent("parked.jar")
            try FileManager.default.moveItem(at: game.jar, to: parked)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            for session in [visible, hidden] {
                let renderer = try #require(session.map?.currentRenderer)
                #expect(renderer.gameData == nil)
                #expect(renderer.gameArtwork == nil)
                #expect(renderer.biomeColors?.biome("test:sample")
                    .color(.water, x: 0, z: 0) == nil)
            }

            try FileManager.default.moveItem(at: parked, to: game.jar)
            let restoredStamp = try #require(CacheKey.fileStamp(for: game.jar))
            #expect(restoredStamp.size == stamp.size && restoredStamp.modified == stamp.modified)
            resources.refreshGameAssets()
            await resources.waitForRefresh()
            #expect(resources.names.minecraft.generation == generation)
            let restored = try #require(await resources.names.minecraft.library())
            let restoredColors = try #require(resources.biomeColors)
            #expect(restoredColors.source == GameResourceSource(data: restored.data,
                artwork: resources.names.minecraft.artwork(for: restored)))
            #expect(restoredColors.sourceKey.catalog == colors.sourceKey.catalog)
            #expect(restoredColors.sourceKey.colorMaps == colors.sourceKey.colorMaps)
            for session in [visible, hidden] {
                let renderer = try #require(session.map?.currentRenderer)
                #expect(renderer.gameData === restored.data)
                #expect((renderer.gameArtwork != nil) == artwork)
                #expect(renderer.biomeColors?.sourceKey == restoredColors.sourceKey)
                #expect(renderer.biomeColors?.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
                #expect(renderer.biomeColors?.biome("test:sample").color(.grass, x: 0, z: 0)
                    == (artwork ? 0xff0000 : nil))
            }
            withExtendedLifetime(original) {}
        } catch { failure = error }
        visible.close(); hidden.close(); resources.close()
        await resources.waitUntilClosed()
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
            #expect(try requiredRenderer(first.map).gameData == nil && requiredRenderer(hidden.map).gameData == nil)
            #expect(resources.gameNames.identity == GameNames.unavailable.identity && resources.newerWorldNotice == nil)
            await gate.waitForCancellation("0"); await gate.waitForRequest("1")
            await gate.finish("1", with: current)
            for await ready in Observations({ hidden.map?.currentRenderer?.gameData === current.data }) where ready { break }
            await gate.finish("0", with: old)
            await resources.waitForRefresh()
            #expect(try requiredRenderer(first.map).gameData === current.data && requiredRenderer(hidden.map).gameData === current.data)
            resources.refreshGameAssets()
            await gate.waitForRequest("2")
            resources.close()
            await gate.waitForCancellation("2")
            await gate.finish("2", with: old)
            await resources.waitUntilClosed()
            #expect(try resources.mapGameResources.data == nil && requiredRenderer(first.map).gameData == nil)
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
        let artworkKey = try #require((try requiredRenderer(map)).colorSourceKey)
        #expect(!map.detailImages.isEmpty)
        let observation = observe(first, source: source)
        let colorReads = Mutex<Int>(0)
        for resources in [first, second] {
            resources.readBiomeColors = { world, data, artwork, previous, reload in
                colorReads.withLock { $0 += 1 }
                return try await WorldResources.readBiomeColors(world, data: data, artwork: artwork, previous: previous, reload: reload)
            }
        }
        names.minecraft.usesGameArtwork = true
        await first.waitForRefresh(); await second.waitForRefresh()
        #expect(colorReads.withLock { $0 } == 0) // Assigning the same choice is not a refresh.

        names.minecraft.usesGameArtwork = false
        await expectUpdate(observation)
        for resources in [first, second] { #expect(resources.gameArtworkLibrary(for: source) == nil && resources.biomeColors?.source.artwork == .unavailable) }
        for session in [a, hidden, b] {
            #expect(try requiredRenderer(session.map).gameArtwork == nil && requiredRenderer(session.map).gameData === library.data
                && (try requiredRenderer(session.map)).biomeColors?.source.artwork == .unavailable)
        }
        #expect(try map.detailImages.isEmpty && requiredRenderer(map).gameSource.artwork == .unavailable)
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        let fallbackPixels = try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes
        #expect(fallbackPixels != originalPixels)
        #expect(first.details.definitions == definitions && first.readers["minecraft:overworld"] === readers["minecraft:overworld"])
        #expect(await names.minecraft.library()?.data === library.data && names.minecraft.generation == source.generation)
        #expect(first.biomeColors?.outlineColor(for: "test:sample", at: .zero) == MapColor(0x123456))
        #expect(colorReads.withLock { $0 } == 2) // One producer per world, independent of tab count.
        names.minecraft.usesGameArtwork = false
        await first.waitForRefresh(); await second.waitForRefresh()
        #expect(colorReads.withLock { $0 } == 2)

        names.minecraft.usesGameArtwork = true
        await first.waitForRefresh(); await second.waitForRefresh(); await map.waitForRenders()
        #expect(first.gameArtworkLibrary(for: source) === library && second.gameArtworkLibrary(for: source) === library)
        #expect(try requiredRenderer(map).colorSourceKey == artworkKey && !map.detailImages.isEmpty)
        #expect(try ItemPictureFixture.pixels(try #require(map.tiles[.init(x: 0, z: 0)]?.image)).bytes == originalPixels)
        #expect(first.details.definitions == definitions)
        #expect(colorReads.withLock { $0 } == 4)
        first.close(); second.close()
        await first.waitUntilClosed(); await second.waitUntilClosed(); await names.minecraft.waitUntilIdle()
        names.minecraft.usesGameArtwork = false
        await first.waitForRefresh(); await second.waitForRefresh()
        #expect(colorReads.withLock { $0 } == 4)
    }

    @Test func gameObservationDoesNotRetainAClosedWorld() async throws {
        let game = try artworkFixture(), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        var world: WorldResources? = try await resources(root, game: game)
        let minecraft = try #require(world?.names.minecraft)
        await world?.waitForRefresh()
        weak let released = world
        world?.close(); await world?.waitUntilClosed()
        world = nil
        #expect(released == nil)
        minecraft.usesGameArtwork = false
        minecraft.forget()
        minecraft.choose(game.root)
        await minecraft.waitUntilIdle()
        #expect(released == nil)
        #expect(try await minecraft.readLibrary() != nil)
        minecraft.forget(); await minecraft.waitUntilIdle()
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

    @Test func numericColorsStayInTerrainAndOutlinesWhileArtworkColorsLoad() async throws {
        let game = try artworkFixture()
        let section = Fixtures.section(y: 0, palette: [.string("minecraft:water")], biomes: ["test:sample"])
        let root = try TestWorld.make(chunks: [.init(x: 0, z: 0,
            nbt: Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3,
                                sections: [section], extra: ["yPos": .int(0)]))],
            dimensionSettings: ["minecraft:overworld": TestWorld.noiseDimension(
                type: .string("minecraft:overworld"),
                noise: .compound(["noise": .compound(["min_y": .int(-64), "height": .int(384)]),
                                  "sea_level": .int(63)]))])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, game: game)
        let session = WorldSession(resources: resources)
        let gate = AsyncReadGate<Void>()
        var failure: (any Error)?
        do {
            resources.names.minecraft.usesGameArtwork = false
            await resources.waitForRefresh()
            let numeric = try #require(resources.biomeColors)
            let map = try #require(session.map), region = RegionPosition(x: 0, z: 0)
            try #require(map.heightScale != nil)
            #expect(numeric.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
            resources.readBiomeColors = { world, data, artwork, previous, reload in
                let colors = try await WorldResources.readBiomeColors(world, data: data, artwork: artwork,
                                                                      previous: previous, reload: reload)
                await gate.read("artwork")
                return colors
            }
            resources.names.minecraft.usesGameArtwork = true
            await gate.waitForRequest("artwork")
            let pending = try requiredRenderer(map)
            #expect(resources.mapGameResources.colorsReady)
            #expect(pending.gameArtwork != nil)
            #expect(resources.biomeColors?.sourceKey == numeric.sourceKey)
            #expect(resources.mapGameResources.biomeColors?.sourceKey == numeric.sourceKey)
            #expect(MapContent(session: session).biomeColors?.sourceKey == numeric.sourceKey)
            #expect(pending.biomeColors?.sourceKey == numeric.sourceKey)
            #expect(pending.colorSourceKey == .biomes(numeric.sourceKey, blending: nil))
            #expect(try !numeric.matchesMetadata(resources.world, source: pending.gameSource))
            let interim = try #require(try await pending.tile(for: region))

            await gate.finish("artwork", with: ())
            await resources.waitForRefresh()
            let complete = try requiredRenderer(map)
            let colors = try #require(complete.biomeColors)
            #expect(colors.sourceKey != numeric.sourceKey)
            #expect(colors.source.artwork == complete.gameSource.artwork)
            #expect(resources.biomeColors?.sourceKey == colors.sourceKey)
            #expect(MapContent(session: session).biomeColors?.sourceKey == colors.sourceKey)
            let finished = try #require(try await complete.tile(for: region))
            // Water has a numeric color, so adding grass/foliage artwork cannot recolor it.
            #expect(try ItemPictureFixture.pixels(interim.full.image).bytes
                == ItemPictureFixture.pixels(finished.full.image).bytes)
            #expect(interim.key != finished.key)

            map.setStyle(.height)
            #expect(map.style == .height)
            #expect(try requiredRenderer(map).colorSourceKey == nil)
        } catch {
            failure = error
        }
        await gate.releaseAllAndFuture(with: ())
        session.close(); resources.close()
        await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
        if let failure { throw failure }
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
        #expect(try requiredRenderer(map).gameData === library.data)
        #expect(names.minecraft.artwork(for: library) == nil && resources.gameArtworkLibrary(for: source) == nil)
        #expect(try await library.data.mapMaterials(for: [.init("minecraft:stone")]).first?.model != nil)
        let colors = try #require((try requiredRenderer(map)).biomeColors)
        #expect(colors.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
        func rendered() async throws -> RegionTileRenderer.RenderedTile {
            var renderer = (try requiredRenderer(map))
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
        #expect(try requiredRenderer(map).biomeColors?.biome("test:sample").color(.water, x: 0, z: 0) == 0x123456)
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
            #expect(!resources.mapGameResources.colorsReady)
            let original = try #require(await names.minecraft.library())
            let originalArtwork = try #require(names.minecraft.artwork(for: original))
            let oldColors = try await original.data.biomeColors(in: resources.world, artwork: originalArtwork)
            sessions.append(WorldSession(resources: resources))
            for session in sessions {
                #expect(try requiredRenderer(session.map).gameData === original.data)
                #expect(try requiredRenderer(session.map).gameArtwork === originalArtwork)
                #expect(try requiredRenderer(session.map).biomeColors == nil)
            }

            // A newly read archive under the same folder generation must be available before
            // its colors. A delayed read from the retired archive cannot reconnect it.
            await assetReads.publish(replacement, to: resources)
            #expect(!resources.mapGameResources.colorsReady)
            for session in sessions {
                #expect(try requiredRenderer(session.map).gameData === replacement.data)
                #expect(try requiredRenderer(session.map).gameArtwork === replacementArtwork)
                #expect(try requiredRenderer(session.map).biomeColors == nil)
            }
            await gate.waitForCancellation("0")
            await gate.waitForRequest("1")
            let current = try await replacement.data.biomeColors(in: resources.world, artwork: replacementArtwork)
            await gate.finish("1", with: current)
            await gate.finish("0", with: oldColors)
            await resources.waitForRefresh()
            #expect(resources.mapGameResources.colorsReady)
            for session in sessions {
                #expect(try requiredRenderer(session.map).gameData === replacement.data)
                #expect(try requiredRenderer(session.map).biomeColors?.sourceKey == current.sourceKey)
            }

            sessions[0].close()
            #expect(!resources.isClosed)
            names.minecraft.forget()
            for session in sessions {
                #expect(try requiredRenderer(session.map).gameData == nil)
                #expect(try requiredRenderer(session.map).gameArtwork == nil)
                #expect(try requiredRenderer(session.map).biomeColors == nil)
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
