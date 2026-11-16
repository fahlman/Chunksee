import ChunkseeKit
import ChunkseeIndex
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldDefinitionAdoptionTests {
    private let neutral = #"{"slots":["any"],"effects":{}}"#
    private let changesHealth = #"{"slots":["head"],"effects":{"minecraft:attributes":[{"id":"test:health","attribute":"minecraft:max_health","amount":4,"operation":"add_value"}]}}"#

    private actor Scans {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    private func fixture(enchantment: String) throws -> URL {
        let root = try TestWorld.make(chunks: [])
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let fields: [String: NBT] = [
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(1), .double(64), .double(2)]), "Health": .float(17),
            "attributes": .list([.compound(["id": .string("minecraft:max_health"), "base": .double(20)])]),
            "equipment": .compound(["head": .compound(["id": .string("minecraft:iron_helmet"), "count": .int(1),
                "components": .compound(["minecraft:enchantments": .compound([enchantment: .int(1)])])])])
        ]
        let uuid = UUID(uuidString: "00000001-0000-0002-0000-000300000004")!
        try Fixtures.writeGzippedNBT(.compound(fields), to: World(contentsOf: root).playerDataDirectory.appendingPathComponent(uuid.uuidString + ".dat"))
        let mob = Fixtures.mob(fields.merging([
            "id": .string("minecraft:wolf"), "Owner": .intArray([1, 2, 3, 4]), "UUID": .intArray([5, 6, 7, 8])
        ]) { $1 })
        try Fixtures.write(try Fixtures.region([.init(localX: 0, localZ: 0, nbt: .compound([
            "DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([mob])
        ]))]), to: dimension.regionURL(.entities, x: 0, z: 0))
        return root
    }

    private func resources(_ root: URL, assetReads: TestGameAssets? = nil,
                           readRegion: @escaping RegionReader.Read = RegionReader.scan) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let result = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root.appendingPathComponent("test-cache"),
            watchWorld: { _, _ in nil }, readRegion: readRegion, readGameAssets: { minecraft in
                if let assetReads { return try await assetReads.read(minecraft) }
                return try await minecraft.readLibrary()
            })
        result.refreshDelay = .zero
        await result.index.waitForIndex()
        return result
    }

    private func expectHealth(_ value: Double?, in resources: WorldResources) async throws {
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        let player = try #require(resources.players.first)
        let creature = try #require(resources.index.index.dimensions["minecraft:overworld"]?.creatures.first?.creature)
        #expect(player.health == 17 && creature.health == 17)
        let enchantments = resources.details.definitions.enchantments
        #expect(player.maximumHealth(enchantments: enchantments) == value)
        #expect(creature.maximumHealth(enchantments: enchantments) == value)
    }

    @Test func definitionChangesResolveCachedHealthWithoutReadingRegionsAgain() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json")
        try write(neutral, to: definition)
        let scans = Scans()
        let read: RegionReader.Read = { dimension, region, options in
            await scans.record()
            return try await RegionReader.scan(dimension, region: region, options: options)
        }
        let resources = try await resources(root, readRegion: read)
        defer { resources.close() }
        try await expectHealth(20, in: resources)
        let before = try #require(resources.readers["minecraft:overworld"])
        let dimension = await before.dimension
        let key = ScanCache.Key(dimension: dimension, region: .init(x: 0, z: 0), options: .init(before.inputs.options))
        let savedCreature = try #require(resources.index.index.dimensions[dimension.id]?.creatures.first?.creature)
        #expect(await scans.count == 1)
        try write(changesHealth, to: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        let after = try #require(resources.readers["minecraft:overworld"])
        #expect(before === after)
        #expect(key == ScanCache.Key(dimension: dimension, region: .init(x: 0, z: 0), options: .init(after.inputs.options)))
        #expect(resources.index.index.dimensions[dimension.id]?.creatures.first?.creature == savedCreature)
        #expect(await scans.count == 1)
        try write("malformed", to: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        #expect(resources.readers[dimension.id] === before)
        #expect(await scans.count == 1)
        try FileManager.default.removeItem(at: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        #expect(resources.readers[dimension.id] === before)
        #expect(await scans.count == 1)
        resources.close(); await resources.waitUntilClosed()

        let reopened = try await self.resources(root, readRegion: read)
        defer { reopened.close() }
        try await expectHealth(nil, in: reopened)
        #expect(reopened.index.index.dimensions[dimension.id]?.creatures.first?.creature == savedCreature)
        #expect(await scans.count == 1)
        try write(neutral, to: definition)
        reopened.worldChanged([definition])
        try await expectHealth(20, in: reopened)
        #expect(reopened.index.index.dimensions[dimension.id]?.creatures.first?.creature == savedCreature)
        #expect(await scans.count == 1)
        reopened.close(); await reopened.waitUntilClosed()
    }

    @Test func installedGameChangesReachHiddenWorldsAndPackOverridesWin() async throws {
        let root = try fixture(enchantment: "minecraft:protection")
        let game = try ItemPictureFixture(extraFiles: ["data/minecraft/enchantment/protection.json": Data(neutral.utf8)])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        try await expectHealth(nil, in: resources)
        resources.names.minecraft.choose(game.root) // No view or scene task is involved.
        try await expectHealth(20, in: resources)
        let definition = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/enchantment/protection.json")
        try write(changesHealth, to: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        try FileManager.default.removeItem(at: definition)
        resources.worldChanged([definition])
        try await expectHealth(20, in: resources)
        resources.names.minecraft.forget()
        try await expectHealth(nil, in: resources)
        resources.close(); await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func leafTagChangesReachOpenSessionsWithoutReplacingReadersOrExplicitChoices() async throws {
        let root = try fixture(enchantment: "test:ward")
        let game = try ItemPictureFixture(extraFiles: [
            "data/minecraft/tags/block/leaves.json": Data(#"{"values":["minecraft:oak_leaves"]}"#.utf8)
        ])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), session = WorldSession(resources: resources)
        defer { session.close() }
        let map = try #require(session.map)
        let choices = MapBlockFilter(hiddenIDs: ["minecraft:oak_leaves"], highlightedIDs: ["example:needles"])
        map.setBlockFilter(choices)
        let readers = resources.readers
        func expectLeaves(_ expected: [String]?) async {
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            #expect(session.details.definitions.leafTag?.members.map(\.id) == expected)
            #expect(map.blockFilter == choices)
            #expect(resources.readers.count == readers.count)
            for (id, reader) in readers { #expect(resources.readers[id] === reader) }
        }
        await expectLeaves(nil)
        resources.names.minecraft.choose(game.root)
        await expectLeaves(["minecraft:oak_leaves"])
        let tag = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/leaves.json")
        try write(#"{"values":["example:needles"]}"#,
                  to: root.appendingPathComponent("datapacks/ChunkseeTest/data/example/tags/block/firs.json"))
        try write(##"{"values":["#example:firs"]}"##, to: tag)
        resources.worldChanged([tag])
        await expectLeaves(["minecraft:oak_leaves", "example:needles"])
        try write(##"{"replace":true,"values":["#example:firs"]}"##, to: tag)
        resources.worldChanged([tag])
        await expectLeaves(["example:needles"])
        try write(#"{"replace":true,"values":[]}"#, to: tag)
        resources.worldChanged([tag])
        await expectLeaves([])
        try write("damaged tag", to: tag)
        resources.worldChanged([tag])
        await expectLeaves(nil)
        try FileManager.default.removeItem(at: tag)
        resources.worldChanged([tag])
        await expectLeaves(["minecraft:oak_leaves"])
        resources.names.minecraft.forget()
        await expectLeaves(nil)
        session.close(); await resources.waitUntilClosed()
        await resources.names.minecraft.waitUntilIdle()
    }

    @Test func biomeListsAndTradesRefreshWithoutReplacingRegionReaders() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(neutral, to: root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json"))
        let resources = try await resources(root)
        defer { resources.close() }
        try await expectHealth(20, in: resources)
        let readers = resources.readers
        let original = resources.details.definitions
        let biomes = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/worldgen/biome/is_overworld.json")
        try write(#"{"replace":true,"values":["example:meadow"]}"#, to: biomes)
        resources.worldChanged([biomes])
        try await expectHealth(20, in: resources)
        #expect(resources.details.definitions.possibleBiomes["minecraft:overworld"] == ["example:meadow"])
        #expect(resources.details.definitions.possibleBiomes != original.possibleBiomes)
        for (id, reader) in readers { #expect(resources.readers[id] === reader) }

        let trades = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/trade_set/farmer/level_1.json")
        try write(#"{"amount":1,"trades":[]}"#, to: trades)
        resources.worldChanged([trades])
        try await expectHealth(20, in: resources)
        #expect(resources.details.definitions.trading != original.trading)
        #expect(resources.readers.count == readers.count)
        for (id, reader) in readers { #expect(resources.readers[id] === reader) }
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func consumedCatalogChangesReplaceReadersAndIdenticalRereadsKeepThem() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        await resources.waitForRefresh()
        let id = "minecraft:overworld", original = try #require(resources.readers[id])
        #expect(original.inputs.options.blockIDs?.contains("minecraft:diamond_ore") == true)
        let ores = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/diamond_ores.json")
        try write(#"{"replace":true,"values":[]}"#, to: ores)
        resources.worldChanged([ores])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        let changedOres = try #require(resources.readers[id])
        #expect(changedOres !== original)
        #expect(changedOres.inputs.options.blockIDs?.contains("minecraft:diamond_ore") == false)
        let villages = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/worldgen/structure/village.json")
        try write(#"{"replace":true,"values":["example:hill_fort"]}"#, to: villages)
        resources.worldChanged([villages])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        let changedGroups = try #require(resources.readers[id])
        #expect(changedGroups !== changedOres && changedGroups.inputs.options == changedOres.inputs.options)
        #expect(changedGroups.structureGroups.group(for: "example:hill_fort") == .village)
        resources.worldChanged([villages])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(resources.readers[id] === changedGroups)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func staleAndClosedWorldDefinitionReadsCannotPublish() async throws {
        let assetReads = TestGameAssets()
        let root = try fixture(enchantment: "minecraft:protection")
        let game = try ItemPictureFixture(extraFiles: [
            "data/minecraft/enchantment/protection.json": Data(neutral.utf8),
            "data/minecraft/tags/block/leaves.json": Data(#"{"values":["example:needles"]}"#.utf8)
        ])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root, assetReads: assetReads), first = try game.resources(), second = try game.resources(), third = try game.resources()
        defer { resources.close() }
        let savedPlayers = resources.playerSnapshot
        resources.readPlayers = { _ in Issue.record("Game changes must not reread saved players"); return nil }
        let blank = try await WorldResources.readDefinitions(resources.world, library: nil).value
        let known = try await WorldResources.readDefinitions(resources.world, library: first.data).value
        let gate = AsyncReadGate<WorldDefinitions>()
        resources.readDefinitions = { _, library, _ in
            guard let library else { return .complete(blank) }
            return .complete(await gate.read(library.identity == first.identity ? "older" : library.identity == second.identity ? "newer" : "closing"))
        }

        await assetReads.publish(first, to: resources)
        await gate.waitForRequest("older")
        await assetReads.publish(second, to: resources)
        await gate.waitForCancellation("older")
        await gate.waitForRequest("newer")
        await gate.finish("newer", with: known)
        await gate.finish("older", with: blank)
        try await expectHealth(20, in: resources)
        #expect(resources.playerSnapshot === savedPlayers)
        #expect(resources.details.definitions.leafTag?.members.map(\.id) == ["example:needles"])
        await assetReads.publish(third, to: resources)
        await gate.waitForRequest("closing")
        let original = resources.playerSnapshot
        resources.close()
        // Closing the shared loader releases its publication. A canceled completion must not
        // restore those facts after closure, just as it cannot replace them while open.
        let closed = resources.playerSnapshot, definitions = resources.details.definitions
        #expect(resources.isClosed && closed !== original && closed.players.isEmpty)
        #expect(definitions == WorldDefinitions())
        await gate.waitForCancellation("closing")
        await gate.finish("closing", with: blank)
        await resources.waitUntilClosed()
        #expect(resources.playerSnapshot === closed && resources.details.definitions == definitions)
    }

    @Test func oneDamagedResourceDoesNotHideOtherReadableDefinitions() throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(neutral, to: root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json"))
        let metadata = root.appendingPathComponent("data/minecraft/world_gen_settings.dat")
        try write("damaged saved metadata", to: metadata)
        let definitions = try WorldDefinitions.read(World(contentsOf: root), assets: nil)
        #expect(definitions.dimensionSettings.isEmpty)
        #expect(definitions.enchantments["test:ward"]?.hasMaximumHealthModifier == false)
        #expect(definitions.possibleBiomes["minecraft:overworld"]?.count == 4)
        #expect(definitions.notableBlocks.blockIDs.contains("minecraft:diamond_ore"))
    }

    @Test func definitionsPublishWhileAPlayerReadIsPendingAndStillAdvanceWhenItFails() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json")
        try write(neutral, to: definition)
        let resources = try await resources(root)
        defer { resources.close() }
        let original = resources.playerSnapshot, definitions = resources.details.definitions
        let players = AsyncReadGate<[PlayerInfo]?>()
        resources.readPlayers = { _ in await players.read("players") }
        try write(changesHealth, to: definition)
        resources.worldChanged([definition, resources.world.playerDataDirectory])
        await players.waitForRequest("players")
        for await value in Observations({ resources.details.definitions }) where value != definitions { break }
        #expect(resources.playerSnapshot === original)
        #expect(resources.players.first?.maximumHealth(enchantments: resources.details.definitions.enchantments) == nil)
        await players.finish("players", with: nil)
        await resources.waitForRefresh()
        #expect(resources.playerSnapshot === original && resources.details.definitions != definitions)
        try await expectHealth(nil, in: resources)
        resources.readPlayers = { await WorldResources.readPlayers($0) }
        resources.worldChanged([resources.world.playerDataDirectory])
        try await expectHealth(nil, in: resources)
        #expect(resources.playerSnapshot !== original)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func playerSavesPublishWhenDefinitionsCannotBeRead() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root)
        defer { resources.close() }
        let original = try #require(resources.players.first), definitions = resources.details.definitions
        let changed = PlayerInfo(uuid: original.uuid, nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(30), .double(64), .double(0)])
        ]))
        resources.readDefinitions = { _, _, _ in throw CocoaError(.fileReadUnknown) }
        resources.readPlayers = { _ in [changed] }
        resources.worldChanged([root.appendingPathComponent("level.dat")])
        await resources.waitForRefresh()
        #expect(resources.players.first?.position?.x == 30)
        #expect(resources.details.definitions == definitions)
        #expect(resources.index.snapshot.players === resources.playerSnapshot)
        resources.close(); await resources.waitUntilClosed()
    }

    @Test func gameDiscoveryDoesNotHoldOrRestartPlayerSaves() async throws {
        let root = try fixture(enchantment: "test:ward"), game = try ItemPictureFixture()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: defaults)
        let discovery = AsyncReadGate<GameResourceLibrary?>(), players = AsyncReadGate<[PlayerInfo]?>()
        let resources = try await WorldResources(snapshot: WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil }, readGameAssets: { _ in await discovery.read("game") })
        defer { resources.close() }
        resources.refreshDelay = .zero
        let original = try #require(resources.players.first)
        let changed = PlayerInfo(uuid: original.uuid, nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(40), .double(64), .double(0)])
        ]))
        resources.readPlayers = { _ in await players.read("players") }
        names.minecraft.choose(game.root)
        await discovery.waitForRequest("game")
        resources.worldChanged([resources.world.playerDataDirectory])
        await players.waitForRequest("players")
        await players.releaseAllAndFuture(with: [changed])
        for await snapshot in Observations({ resources.playerSnapshot })
            where snapshot.players.first?.position?.x == 40 { break }
        await discovery.finish("game", with: nil)
        await resources.waitForRefresh()
        #expect(await players.requested == ["players"])
        #expect(resources.players.first?.position?.x == 40)
        resources.close(); await resources.waitUntilClosed()
        await names.minecraft.waitUntilIdle()
    }

    @Test func failedDimensionMetadataRetainsItsScaleWhileOtherDefinitionsAdvance() async throws {
        let root = try TestWorld.make(chunks: [], dimensionSettings: [
            "minecraft:overworld": TestWorld.noiseDimension(type: .string("minecraft:overworld"),
                                                           noise: .string("minecraft:overworld"))
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let enchantment = root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json")
        try write(neutral, to: enchantment)
        let world = try World(contentsOf: root), dimensions = world.dimensions()
        let original = try WorldDefinitions.read(world, dimensions: dimensions, assets: nil)
        #expect(original.isComplete && !original.value.dimensionSettings.isEmpty)
        let metadata = root.appendingPathComponent("data/minecraft/world_gen_settings.dat")
        try write("interrupted saved-data write", to: metadata)
        #expect(throws: (any Error).self) { try world.dimensionSettings(assets: nil) }
        try write(changesHealth, to: enchantment)
        let partial = try WorldDefinitions.read(world, dimensions: dimensions, assets: nil, retaining: original.value)
        #expect(!partial.isComplete)
        #expect(partial.value.dimensionSettings == original.value.dimensionSettings)
        #expect(partial.value.enchantments["test:ward"]?.hasMaximumHealthModifier == true)
        try FileManager.default.removeItem(at: metadata)
        let removed = try WorldDefinitions.read(world, dimensions: dimensions, assets: nil, retaining: partial.value)
        #expect(removed.isComplete && removed.value.dimensionSettings.isEmpty)
    }

    @Test func failedBlockTagsRetainReadersWhileIndependentDefinitionsAdvance() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("datapacks/ChunkseeTest")
        let enchantment = pack.appendingPathComponent("data/test/enchantment/ward.json")
        let tag = pack.appendingPathComponent("data/minecraft/tags/block/diamond_ores.json")
        try write(neutral, to: enchantment)
        let scans = Scans()
        let read: RegionReader.Read = { dimension, region, options in
            await scans.record()
            return try await RegionReader.scan(dimension, region: region, options: options)
        }
        let resources = try await resources(root, readRegion: read)
        defer { resources.close() }
        await resources.waitForRefresh()
        let original = resources.details.definitions
        let reader = try #require(resources.readers["minecraft:overworld"])
        let dimension = await reader.dimension
        let region = RegionPosition(x: 0, z: 0)
        let key = ScanCache.Key(dimension: dimension, region: region, options: .init(reader.inputs.options))
        let count = await scans.count
        #expect(original.notableBlocks.blockIDs.contains("minecraft:diamond_ore"))

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tag.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tag.path) }
        #expect(throws: (any Error).self) {
            try resources.world.tags(for: ["minecraft:diamond_ores"], in: "block", assets: nil)
        }
        try write(changesHealth, to: enchantment)
        resources.worldChanged([pack])
        await resources.waitForRefresh(); await resources.index.waitForIndex()
        let partial = resources.details.definitions
        #expect(partial.enchantments["test:ward"]?.hasMaximumHealthModifier == true)
        #expect(partial.notableBlocks == original.notableBlocks)
        let retained = try #require(resources.readers[dimension.id])
        #expect(retained === reader)
        #expect(ScanCache.Key(dimension: dimension, region: region, options: .init(retained.inputs.options)) == key)
        #expect(await scans.count == count)

        // The same source gets a new demand. A now-readable empty tag removes its old members.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tag.path)
        try write(#"{"replace":true,"values":[]}"#, to: tag)
        resources.worldChanged([pack])
        await resources.waitForRefresh(); await resources.index.waitForIndex()
        #expect(!resources.details.definitions.notableBlocks.blockIDs.contains("minecraft:diamond_ore"))
        #expect(resources.readers[dimension.id] !== reader)
        resources.close(); await resources.waitUntilClosed()
    }
}
