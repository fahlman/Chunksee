import ChunkseeKit
import ChunkseeIndex
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldDefinitionAdoptionTests {
    private let neutral = #"{"slots":["any"],"effects":{}}"#
    private let changesHealth = #"{"slots":["head"],"effects":{"minecraft:attributes":[{"id":"test:health","attribute":"minecraft:max_health","amount":4,"operation":"add_value"}]}}"#

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

    private func resources(_ root: URL) async throws -> WorldResources {
        let defaults = TestDefaults.make()
        let result = try WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root.appendingPathComponent("test-cache"),
            watchWorld: { _, _ in nil })
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
        #expect(player.maxHealth == value && creature.maxHealth == value)
        #expect(resources.readers.values.allSatisfy { $0.scanOptions.enchantments == resources.details.definitions.enchantments })
    }

    @Test func initialPlayersAndScansUseTheSameCustomPackDefinitions() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json")
        try write(neutral, to: definition)
        let resources = try await resources(root)
        defer { resources.close() }
        try await expectHealth(20, in: resources)
        let before = try #require(resources.readers["minecraft:overworld"])
        let dimension = await before.dimension
        let key = ScanCache.Key(dimension: dimension, region: .init(x: 0, z: 0), options: before.scanOptions)
        try write(changesHealth, to: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        let after = try #require(resources.readers["minecraft:overworld"])
        #expect(before !== after)
        #expect(key != ScanCache.Key(dimension: dimension, region: .init(x: 0, z: 0), options: after.scanOptions))
        try write("malformed", to: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        try FileManager.default.removeItem(at: definition)
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        resources.close(); await resources.waitUntilClosed()
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

    @Test func staleAndClosedWorldDefinitionReadsCannotPublish() async throws {
        let root = try fixture(enchantment: "minecraft:protection")
        let game = try ItemPictureFixture(extraFiles: [
            "data/minecraft/enchantment/protection.json": Data(neutral.utf8),
            "data/minecraft/tags/block/leaves.json": Data(#"{"values":["example:needles"]}"#.utf8)
        ])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let resources = try await resources(root), first = try game.library(), second = try game.library(), third = try game.library()
        defer { resources.close() }
        let blank = try await WorldResources.readDefinitions(resources.world, library: nil)
        let known = try await WorldResources.readDefinitions(resources.world, library: first)
        let gate = AsyncReadGate<WorldResources.DefinitionSnapshot>()
        resources.readDefinitions = { _, library in
            guard let library else { return blank }
            return await gate.read(library.identity == first.identity ? "older" : library.identity == second.identity ? "newer" : "closing")
        }
        let source = WorldGameAssetSource(generation: resources.names.minecraft.generation)
        resources.prepareGameAssets(source)
        resources.setGameAssets(first, source: source)
        await gate.waitForRequest("older")
        resources.setGameAssets(second, source: source)
        await gate.waitForCancellation("older")
        await gate.waitForRequest("newer")
        await gate.finish("newer", with: known)
        await gate.finish("older", with: blank)
        try await expectHealth(20, in: resources)
        #expect(resources.details.definitions.leafTag?.members.map(\.id) == ["example:needles"])
        resources.setGameAssets(third, source: source)
        await gate.waitForRequest("closing")
        let original = resources.playerSnapshot, definitions = resources.details.definitions
        resources.close()
        await gate.waitForCancellation("closing")
        await gate.finish("closing", with: blank)
        await resources.waitUntilClosed()
        #expect(resources.playerSnapshot === original && resources.details.definitions == definitions)
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

    @Test func failedPlayerRefreshKeepsOneCoherentSnapshotUntilTheNextSave() async throws {
        let root = try fixture(enchantment: "test:ward")
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("datapacks/ChunkseeTest/data/test/enchantment/ward.json")
        try write(neutral, to: definition)
        let resources = try await resources(root)
        defer { resources.close() }
        let original = resources.playerSnapshot, definitions = resources.details.definitions
        resources.readPlayers = { _, _ in nil }
        try write(changesHealth, to: definition)
        resources.worldChanged([definition])
        await resources.waitForRefresh()
        #expect(resources.playerSnapshot === original && resources.details.definitions == definitions)
        try await expectHealth(20, in: resources)
        resources.readPlayers = { await WorldResources.readPlayers($0, enchantments: $1) }
        resources.worldChanged([definition])
        try await expectHealth(nil, in: resources)
        resources.close(); await resources.waitUntilClosed()
    }
}
