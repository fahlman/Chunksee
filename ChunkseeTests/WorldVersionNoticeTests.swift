import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldVersionNoticeTests {
    private func saved(_ number: Int?, name: String? = "Saved Snapshot") throws -> SavedMinecraftVersion {
        var fields: [String: NBT] = [:]
        if let number { fields["DataVersion"] = .int(Int32(number)) }
        if let name { fields["Version"] = .compound(["Name": .string(name)]) }
        let root = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound(fields)]), to: root.appendingPathComponent("level.dat"))
        return SavedMinecraftVersion(try World(contentsOf: root).level)
    }

    private func game(_ number: Int, name: String = "Selected Release") throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: ["version.json": ItemPictureFixture.json([
            "id": name, "world_version": number, "stable": true
        ])])
    }

    private func saveVersion(_ number: Int?, name: String? = "Saved Snapshot", in root: URL) throws {
        let file = root.appendingPathComponent("level.dat")
        var fields = try #require(try NBT.read(contentsOf: file)["Data"]?.compound)
        fields["DataVersion"] = number.map { .int(Int32($0)) }
        fields["Version"] = name.map { .compound(["Name": .string($0)]) }
        try Data(Compression.deflate(NBT.compound(["Data": .compound(fields)]).serialized(), gzip: true))
            .write(to: file, options: .atomic)
    }

    private func resources(_ root: URL, defaults: UserDefaults, id: UUID = UUID()) async throws -> WorldResources {
        let snapshot = try await WorldSnapshot.read(root)
        let resources = WorldResources(snapshot: snapshot, names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), settings: WorldSettings(id: id, defaults: defaults),
            cacheRoot: nil, watchWorld: { _, _ in nil })
        resources.refreshDelay = .zero
        return resources
    }

    @Test(arguments: [nil, 5_999, 6_000, 6_001, 9_999] as [Int?])
    func comparisonUsesDataVersionsAndNeverNames(_ number: Int?) throws {
        let selected = try JSONDecoder().decode(GameAssets.Version.self,
            from: ItemPictureFixture.json(["id": "9999 Release", "world_version": 6_000]))
        let notice = WorldVersionNotice(saved: try saved(number, name: "0001 Snapshot"), game: selected)
        #expect((notice != nil) == (number.map { $0 > 6_000 } ?? false))
        if let notice {
            #expect(notice.message(locale: Locale(identifier: "en_US")) == "This world was saved with Minecraft 0001 Snapshot, which is newer than the selected Minecraft 9999 Release. Chunksee will show what it can read.")
        }
    }

    @Test func missingVersionNameDoesNotInventOneOrSuppressTheNotice() throws {
        let selected = try JSONDecoder().decode(GameAssets.Version.self,
            from: ItemPictureFixture.json(["id": "Selected Release", "world_version": 6_000]))
        let version = try saved(6_001, name: nil)
        let notice = try #require(WorldVersionNotice(saved: version, game: selected))
        #expect(notice.message(locale: Locale(identifier: "en_US")) == "This world was saved with a newer Minecraft version than the selected Minecraft Selected Release. Chunksee will show what it can read.")
    }

    @Test func choosingReplacingRemovingAndClosingGameFilesUpdatesTheNotice() async throws {
        let root = try TestWorld.make(chunks: []), older = try game(6_000), newer = try game(6_002, name: "Next Release")
        defer { older.remove(); newer.remove(); try? FileManager.default.removeItem(at: root) }
        try saveVersion(6_001, in: root)
        let resources = try await resources(root, defaults: TestDefaults.make())
        defer { resources.close() }
        #expect(resources.newerWorldNotice == nil)
        resources.names.minecraft.choose(older.root)
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        _ = withObservationTracking { resources.newerWorldNotice } onChange: { continuation.yield(true) }
        await resources.waitForRefresh()
        continuation.finish()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next(isolation: #isolation) == true)
        #expect(resources.newerWorldNotice?.gameName == "Selected Release")
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        let oldLibrary = try #require(resources.gameAssetLibrary(for: source))
        resources.names.minecraft.choose(newer.root)
        await resources.waitForRefresh()
        #expect(resources.newerWorldNotice == nil)
        resources.setGameAssets(oldLibrary, source: source)
        #expect(resources.newerWorldNotice == nil)
        resources.names.minecraft.choose(older.root)
        await resources.waitForRefresh()
        #expect(resources.newerWorldNotice != nil)
        resources.names.minecraft.forget()
        #expect(resources.newerWorldNotice == nil && resources.newerWorldBanner == nil)
        resources.names.minecraft.choose(older.root)
        await resources.waitForRefresh()
        #expect(resources.newerWorldNotice != nil)
        resources.close()
        #expect(resources.newerWorldNotice == nil)
        await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func bannerIsShownOnceAndWorldInfoKeepsTheNoticeAfterDismissalAndReopening() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(6_000)
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        try saveVersion(6_001, in: root)
        let defaults = TestDefaults.make(), id = UUID()
        let first = try await resources(root, defaults: defaults, id: id)
        defer { first.close() }
        first.names.minecraft.choose(game.root)
        await first.waitForRefresh()
        let notice = try #require(first.newerWorldBanner)
        first.presentNewerWorldNotice(notice)
        #expect(first.newerWorldBanner == notice)
        first.dismissNewerWorldNotice(notice)
        #expect(first.newerWorldBanner == nil && first.newerWorldNotice == notice)
        first.presentNewerWorldNotice(notice) // A delayed sibling view cannot reopen a dismissed banner.
        #expect(first.newerWorldBanner == nil)
        first.close(); await first.waitUntilClosed(); await first.names.minecraft.waitUntilIdle()

        let reopened = try await resources(root, defaults: defaults, id: id)
        defer { reopened.close() }
        reopened.refreshGameAssets()
        await reopened.waitForRefresh()
        #expect(reopened.newerWorldBanner == nil && reopened.newerWorldNotice == notice)
        try saveVersion(6_003, name: "Later Snapshot", in: root)
        reopened.worldChanged([root.appendingPathComponent("level.dat")])
        await reopened.waitForRefresh()
        #expect(reopened.newerWorldBanner?.worldName == "Later Snapshot")
        #expect(reopened.newerWorldNotice?.id != notice.id)
        reopened.dismissNewerWorldNotice(notice) // A delayed action cannot dismiss the new comparison.
        #expect(reopened.newerWorldBanner != nil)
        let updated = try #require(reopened.newerWorldBanner)
        reopened.presentNewerWorldNotice(updated)
        reopened.close(); await reopened.waitUntilClosed(); await reopened.names.minecraft.waitUntilIdle()
        let again = try await resources(root, defaults: defaults, id: id)
        defer { again.close() }
        again.refreshGameAssets(); await again.waitForRefresh()
        #expect(again.newerWorldBanner == nil && again.newerWorldNotice == updated)
        again.close(); await again.waitUntilClosed(); await again.names.minecraft.waitUntilIdle()
    }

    @Test func saveChangesRefreshBothVersionNamesAndComparisonAndUnreadableSavesKeepTheLastFacts() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(6_000)
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        try saveVersion(6_000, in: root)
        let resources = try await resources(root, defaults: TestDefaults.make())
        defer { resources.close() }
        resources.names.minecraft.choose(game.root)
        await resources.waitForRefresh()
        #expect(resources.newerWorldNotice == nil)
        let file = root.appendingPathComponent("level.dat")
        try saveVersion(6_001, name: "New Snapshot", in: root)
        resources.worldChanged([file]); await resources.waitForRefresh()
        let notice = try #require(resources.newerWorldNotice)
        #expect(notice.worldName == "New Snapshot" && resources.savedVersion.name == "New Snapshot")
        let saved = try Data(contentsOf: file)
        try Data([0xFF]).write(to: file, options: .atomic)
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(resources.newerWorldNotice == notice)
        try saved.write(to: file, options: .atomic)
        try saveVersion(nil, name: nil, in: root)
        resources.worldChanged([file]); await resources.waitForRefresh()
        #expect(resources.newerWorldNotice == nil && resources.savedVersion.name == nil)
        resources.close(); await resources.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
    }

    @Test func newerWorldStillRendersTerrainAndKeepsPlayersStructuresAndMobs() async throws {
        var terrain = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var fields = try #require(terrain.nbt.compound)
        fields["structures"] = .compound(["starts": .compound(["minecraft:stronghold": .compound([
            "id": .string("minecraft:stronghold"), "ChunkX": .int(0), "ChunkZ": .int(0),
            "Children": .list([.compound(["id": .string("minecraft:shstart"), "BB": .intArray([0, 64, 0, 9, 73, 9])])])
        ])])])
        terrain.nbt = .compound(fields)
        let root = try TestWorld.make(chunks: [terrain]), game = try game(6_000)
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        try saveVersion(6_001, in: root)
        let world = try World(contentsOf: root), dimension = try #require(world.dimension("overworld"))
        let player: [String: NBT] = ["DataVersion": .int(6_001), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(1), .double(64), .double(2)]), "Health": .float(17)]
        let playerID = UUID()
        try Fixtures.writeGzippedNBT(.compound(player), to: world.playerDataDirectory.appendingPathComponent(playerID.uuidString + ".dat"))
        let sheep = Fixtures.mob(["id": .string("minecraft:sheep"), "UUID": .intArray([1, 2, 3, 4]),
            "Pos": .list([.double(3), .double(16), .double(4)]), "Health": .float(8)])
        try Fixtures.write(try Fixtures.region([.init(localX: 0, localZ: 0, nbt: .compound([
            "DataVersion": .int(6_001), "Position": .intArray([0, 0]), "Entities": .list([sheep])
        ]))]), to: dimension.regionURL(.entities, x: 0, z: 0))
        let resources = try await resources(root, defaults: TestDefaults.make())
        let session = WorldSession(resources: resources)
        defer { session.close() }
        resources.names.minecraft.choose(game.root)
        await resources.waitForRefresh(); await resources.index.waitForIndex()
        #expect(resources.newerWorldNotice != nil)
        #expect(resources.players.map(\.uuid) == [playerID])
        #expect(session.presentation.selectedIndex.structures.count == 1)
        #expect(session.presentation.selectedIndex.mobTypes.kind("minecraft:sheep")?.count == 1)
        let map = try #require(session.map)
        map.requestTiles(visibleIn: .init(width: 128, height: 128))
        await map.waitForRenders()
        #expect(map.tiles[.init(x: 0, z: 0)] != nil)
        session.close(); await session.waitUntilClosed(); await resources.names.minecraft.waitUntilIdle()
    }
}
