import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldPreparationTests {
    private func game(_ name: String) throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "data/test/enchantment/\(name).json": Data(#"{"slots":["any"],"effects":{}}"#.utf8)
        ])
    }

    private actor Scans {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func model(game: ItemPictureFixture, cache: URL?, scans: Scans) -> AppModel {
        let model = AppModel(defaults: TestDefaults.make(), cacheRoot: cache, readRegion: { dimension, region, options in
            await scans.record()
            return try await RegionReader.scan(dimension, region: region, options: options)
        })
        model.names.minecraft.choose(game.root)
        return model
    }

    private func open(_ root: URL, model: AppModel) async throws -> WorldSession {
        try model.worldFolders.remember(root)
        let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
        let document = root.appendingPathComponent("dimensions/minecraft/overworld")
        guard case .dimension(let snapshot) = try await reader.readFolder(document) else { throw WorldOpenError.notADimension }
        return try await snapshot.makeSession(in: model)
    }

    private func cacheFiles(_ root: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return try Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "lzfse" }.map {
            ($0.path, try Data(contentsOf: $0))
        })
    }

    @Test func unchangedReopenUsesTheCompletedCacheWithEitherArtworkSetting() async throws {
        let game = try self.game("ward"), changedGame = try self.game("replacement")
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        let cache = try Fixtures.tempDirectory(), scans = Scans()
        defer { game.remove(); changedGame.remove(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        let world = try World(contentsOf: root)
        try Fixtures.writeGzippedNBT(.compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(1), .double(64), .double(2)]), "Health": .float(17),
            "attributes": .list([.compound(["id": .string("minecraft:max_health"), "base": .double(20)])]),
            "equipment": .compound(["head": .compound(["id": .string("minecraft:iron_helmet"), "count": .int(1),
                "components": .compound(["minecraft:enchantments": .compound(["test:ward": .int(1)])])])])
        ]), to: world.playerDataDirectory.appendingPathComponent("00000001-0000-0002-0000-000300000004.dat"))
        let initial = try await WorldSnapshot.read(root)
        #expect(initial.details.definitions.enchantments["test:ward"] == nil)
        #expect(initial.players.first?.maxHealth == nil)
        initial.access.release()

        let firstModel = model(game: game, cache: cache, scans: scans)
        let first = try await open(root, model: firstModel)
        defer { first.close() }
        #expect(first.resources.details.definitions.enchantments["test:ward"] != nil)
        #expect(first.players.first?.maxHealth == 20)
        let firstReader = try #require(first.resources.readers["minecraft:overworld"])
        #expect(firstReader.scanOptions.enchantments == first.resources.details.definitions.enchantments)
        await first.resources.index.waitForIndex()
        first.resources.refreshGameAssets()
        await first.resources.waitForRefresh()
        #expect(first.resources.readers["minecraft:overworld"] === firstReader)
        #expect(await scans.count == 1)
        first.close(); await first.waitUntilClosed()
        let saved = try cacheFiles(cache)
        #expect(saved.count == 1)

        for artwork in [false, true] {
            let nextModel = model(game: game, cache: cache, scans: scans)
            nextModel.names.minecraft.usesGameArtwork = artwork
            let next = try await open(root, model: nextModel)
            defer { next.close() }
            await next.resources.index.waitForIndex()
            next.resources.refreshGameAssets()
            await next.resources.waitForRefresh()
            #expect(next.resources !== first.resources)
            #expect(next.players.first?.maxHealth == 20)
            #expect(await scans.count == 1)
            #expect(try cacheFiles(cache) == saved)
            next.close(); await next.waitUntilClosed(); await nextModel.names.minecraft.waitUntilIdle()
        }

        let changedModel = model(game: changedGame, cache: cache, scans: scans)
        let changed = try await open(root, model: changedModel)
        defer { changed.close() }
        await changed.resources.index.waitForIndex()
        #expect(await scans.count == 2)
        #expect(changed.resources.details.definitions.enchantments["test:replacement"] != nil)
        #expect(changed.players.first?.maxHealth == nil)
        #expect(try cacheFiles(cache) != saved)
        changed.close(); await changed.waitUntilClosed(); await changedModel.names.minecraft.waitUntilIdle()
        await firstModel.names.minecraft.waitUntilIdle()
    }

    @Test func concurrentFreshSnapshotsStillCreateOneWorldAndOneScan() async throws {
        let game = try self.game("ward"), scans = Scans()
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let model = model(game: game, cache: nil, scans: scans)
        let a = try await WorldSnapshot.read(root), b = try await WorldSnapshot.read(root)
        let first = Task { try await model.resources(for: a) }
        let second = Task { try await model.resources(for: b) }
        let one = try await first.value, two = try await second.value
        defer { one.close(); two.close() }
        #expect(one === two)
        await one.index.waitForIndex()
        #expect(await scans.count == 1)
        one.close(); await one.waitUntilClosed(); await model.names.minecraft.waitUntilIdle()
    }

    @Test(arguments: [false, true])
    func changingTheGameSourceWhileOpeningRejectsTheRetiredDefinitions(remove: Bool) async throws {
        let old = try self.game("old"), new = try self.game("new"), root = try TestWorld.make(chunks: [])
        defer { old.remove(); new.remove(); try? FileManager.default.removeItem(at: root) }
        let minecraft = MinecraftResources(defaults: TestDefaults.make())
        minecraft.choose(old.root)
        let library = try #require(await minecraft.library()), snapshot = try await WorldSnapshot.read(root)
        defer { snapshot.access.release() }
        let retired = try await WorldPreparation.readingGameData(snapshot, library: library.data)
        let gate = AsyncReadGate<WorldSnapshot>()
        let task = Task {
            try await WorldPreparation.read(snapshot, minecraft: minecraft) { snapshot, data in
                if data.identity == library.identity { return await gate.read("retired") }
                return try await WorldPreparation.readingGameData(snapshot, library: data)
            }
        }
        await gate.waitForRequest("retired")
        if remove { minecraft.forget() } else { minecraft.choose(new.root) }
        await gate.finish("retired", with: retired)
        let prepared = try await task.value
        #expect(prepared.source.generation == minecraft.generation)
        #expect(prepared.snapshot.details.definitions.enchantments["test:old"] == nil)
        #expect((prepared.snapshot.details.definitions.enchantments["test:new"] != nil) == !remove)
        #expect((prepared.library == nil) == remove)
        await minecraft.waitUntilIdle()
    }

    @Test func cancelledOpeningDoesNotPublishAReadThatFinishesLate() async throws {
        let game = try self.game("ward"), root = try TestWorld.make(chunks: [])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let minecraft = MinecraftResources(defaults: TestDefaults.make())
        minecraft.choose(game.root)
        let snapshot = try await WorldSnapshot.read(root), gate = AsyncReadGate<WorldSnapshot>()
        defer { snapshot.access.release() }
        let task = Task {
            try await WorldPreparation.read(snapshot, minecraft: minecraft) { _, _ in await gate.read("opening") }
        }
        await gate.waitForRequest("opening")
        task.cancel()
        await gate.waitForCancellation("opening")
        await gate.finish("opening", with: snapshot)
        await #expect(throws: CancellationError.self) { try await task.value }
        await minecraft.waitUntilIdle()
    }
}
