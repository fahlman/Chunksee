import ChunkseeKit
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct WorldRefreshWorkTests {
    private func makeResources() async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        resources.refreshDelay = .zero
        return (url, resources)
    }

    @Test(.timeLimit(.minutes(1))) func closingCancelsTheReadAndDropsScheduledRefreshes() async throws {
        let (url, resources) = try await makeResources()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<[PlayerInfo]>(), scheduling = AsyncReadGate<Void>()
        resources.waitBeforeRefresh = { _ in await scheduling.read("save") }
        let file = url.appendingPathComponent("level.dat")
        resources.readPlayers = { _, _ in await gate.read("older") }
        resources.worldChanged([file])
        await scheduling.waitForRequest("save"); await scheduling.finish("save", with: ())
        await gate.waitForRequest("older")
        resources.readPlayers = { _, _ in await gate.read("newer") }
        resources.worldChanged([file])
        await scheduling.waitForRequest("save", count: 2)
        resources.close()
        await scheduling.waitForCancellation("save"); await scheduling.finish("save", with: ())
        let closedPlayers = resources.playerSnapshot
        await gate.waitForCancellation("older")
        let late = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(100), .double(64), .double(0)]),
        ]))
        await gate.finish("older", with: [late])
        await resources.waitForRefresh()
        await resources.waitUntilClosed()
        #expect(resources.playerSnapshot === closedPlayers && resources.players.isEmpty)
        resources.worldChanged([file])
        await resources.waitForRefresh()
        #expect(await gate.requested == ["older"])
    }

    @Test(.timeLimit(.minutes(1))) func waitingForRefreshDoesNotWaitForAnotherWorldTask() async throws {
        let (url, resources) = try await makeResources()
        defer { try? FileManager.default.removeItem(at: url) }
        let unrelated = AsyncReadGate<Void>(), players = AsyncReadGate<[PlayerInfo]>()
        resources.backgroundWork.start(priority: .utility) { await unrelated.read("other") }
        await unrelated.waitForRequest("other")
        resources.readPlayers = { _, _ in await players.read("players") }
        resources.worldChanged([url.appendingPathComponent("level.dat")])
        await players.waitForRequest("players")
        await players.finish("players", with: [])
        await resources.waitForRefresh() // Must return while the unrelated task is still held.
        #expect(!resources.isClosed && !resources.backgroundWork.isClosed)
        resources.close()
        await unrelated.waitForCancellation("other")
        await unrelated.finish("other", with: ())
        await resources.waitUntilClosed()
    }
}
