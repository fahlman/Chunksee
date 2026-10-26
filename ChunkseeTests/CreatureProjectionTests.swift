import ChunkseeKit
import ChunkseeIndex
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct CreatureProjectionTests {
    private let fixtures = ShoulderPetTests()

    private func player(_ x: Double) -> PlayerInfo {
        PlayerInfo(uuid: fixtures.carrier, nbt: fixtures.playerData(pets: [fixtures.parrot(fixtures.bird)],
            dimension: .string(fixtures.overworld), position: [x, 64, 0]))
    }

    private func content() throws -> DimensionContent {
        var result = DimensionContent()
        let creature = try #require(Creature(fixtures.parrot(fixtures.bird)))
        result.creatures = [try #require(CreatureMarker(creature, dimension: fixtures.overworld))]
        return result
    }

    @Test func newerPlayersPublishTogetherAndAnOlderProjectionCannotReplaceThem() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let players = PlayerRoster([player(1)]), gate = AsyncReadGate<Bool>()
        let part = try content()
        let index = WorldIndexStore(readers: [reader], work: BackgroundWork(), firstDimension: nil,
            playerRoster: players, projectCreatures: { base, pets in
                _ = await gate.read(String(pets[0].location!.x))
                return await base.including(pets)
            }, readDimension: { _, _, _ in part })
        await gate.waitForRequest("1.0")
        let original = index.playerSnapshot
        players.publish([player(2)])
        await gate.waitForRequest("2.0")
        await gate.waitForCancellation("1.0")
        #expect(index.playerSnapshot === original && index.index.creatures.isEmpty)
        await gate.finish("2.0", with: true)
        await index.waitForIndex()
        let current = try #require(index.index.dimensions[dimension.id])
        #expect(index.playerSnapshot === players.snapshot)
        #expect(current.creatures.count == 1 && current.creatures[0].position == CGPoint(x: 2, y: 0))
        #expect(current.mobTypes.kind("minecraft:parrot")?.count == 1)
        let revision = index.revision
        await gate.finish("1.0", with: true)
        await index.waitForTasks()
        #expect(index.revision == revision && index.index.creatures[0].value.position.x == 2)
        index.cancel(); await index.waitForTasks(); await reader.close()
    }

    @Test func aNewIndexPassReplacesThePendingProjectionAndRemovingPetsRestoresRegionFacts() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let players = PlayerRoster([player(1)]), gate = AsyncReadGate<Bool>(), numbers = ReadNumbers()
        let part = try content()
        let index = WorldIndexStore(readers: [reader], work: BackgroundWork(), firstDimension: nil,
            playerRoster: players, projectCreatures: { base, pets in
                _ = await gate.read(String(await numbers.next()))
                return await base.including(pets)
            }, readDimension: { _, _, _ in part })
        await gate.waitForRequest("0")
        index.rebuild(firstDimension: nil)
        await gate.waitForRequest("1")
        await gate.waitForCancellation("0")
        players.publish([])
        await index.waitForProjection()
        await gate.waitForCancellation("1")
        #expect(index.playerSnapshot.players.isEmpty)
        #expect(index.index.dimensions[dimension.id]?.creatures[0].position.x == 999)
        let revision = index.revision
        await gate.finishAll(with: true)
        await index.waitForTasks()
        #expect(index.revision == revision && index.playerSnapshot === players.snapshot)
        index.cancel(); await index.waitForTasks(); await reader.close()
    }

    @Test func closingDrainsPendingProjectionWithoutPublishingItsResult() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let players = PlayerRoster([player(1)]), gate = AsyncReadGate<Bool>()
        let part = try content()
        let index = WorldIndexStore(readers: [reader], work: BackgroundWork(), firstDimension: nil,
            playerRoster: players, projectCreatures: { base, pets in
                _ = await gate.read("held")
                return await base.including(pets)
            }, readDimension: { _, _, _ in part })
        await gate.waitForRequest("held")
        index.cancel()
        await gate.waitForCancellation("held")
        var drained = false
        let closing = Task.immediate { await index.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("held", with: true)
        await closing.value
        #expect(drained && index.index.creatures.isEmpty)
        await reader.close()
    }
}
