import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct WorldRefreshWorkTests {
    private func makeResources() async throws -> (URL, WorldResources) {
        let url = try TestWorld.make(chunks: []), defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        resources.refreshDelay = .zero
        return (url, resources)
    }

    @Test(.timeLimit(.minutes(1))) func closingCancelsEveryOverlappingRefreshAndRejectsLatePlayers() async throws {
        let (url, resources) = try await makeResources()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncReadGate<[PlayerInfo]>()
        let original = resources.playerSnapshot, file = url.appendingPathComponent("level.dat")
        resources.readPlayers = { _, _ in await gate.read("older") }
        resources.worldChanged([file])
        await gate.waitForRequest("older")
        resources.readPlayers = { _, _ in await gate.read("newer") }
        resources.worldChanged([file])
        await gate.waitForRequest("newer")
        resources.close()
        await gate.waitForCancellation("older")
        await gate.waitForCancellation("newer")
        let late = PlayerInfo(uuid: UUID(), nbt: .compound([
            "DataVersion": .int(5023), "Dimension": .string("minecraft:overworld"),
            "Pos": .list([.double(100), .double(64), .double(0)]),
        ]))
        await gate.finish("newer", with: [late])
        await gate.finish("older", with: [late])
        await resources.waitForRefresh()
        await resources.waitUntilClosed()
        #expect(resources.playerSnapshot === original)
        resources.worldChanged([file])
        await resources.waitForRefresh()
        #expect(await gate.requested == ["older", "newer"])
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
