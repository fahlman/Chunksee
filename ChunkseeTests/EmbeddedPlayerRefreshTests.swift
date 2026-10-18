import ChunkseeKit
import Foundation
import Testing
@testable import Chunksee

@Suite struct EmbeddedPlayerRefreshTests {
    private func writeLevel(_ url: URL, health: Float?) throws {
        var data: [String: NBT] = ["LevelName": .string("Embedded Player"), "DataVersion": .int(2586)]
        if let health {
            data["Player"] = .compound([
                "UUID": .intArray([1, 2, 3, 4]), "Dimension": .int(0), "playerGameType": .int(0),
                "Health": .float(health), "Pos": .list([.double(Double(health)), .double(64), .double(2)]),
            ])
        }
        try Data(Compression.deflate(NBT.compound(["Data": .compound(data)]).serialized(), gzip: true))
            .write(to: url.appendingPathComponent("level.dat"), options: .atomic)
    }

    private func withWorld(_ body: (URL, WorldResources) async throws -> Void) async throws {
        let url = try TestWorld.make(chunks: [])
        var opened: WorldResources?
        do {
            try writeLevel(url, health: 4)
            let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
            let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                           savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
            opened = resources
            resources.refreshDelay = .zero
            await resources.index.waitForIndex()
            try await body(url, resources)
        } catch {
            opened?.close()
            await opened?.waitUntilClosed()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        opened?.close()
        await opened?.waitUntilClosed()
        try FileManager.default.removeItem(at: url)
    }

    @Test func changedEmbeddedDataReachesTheDefaultReaderAndActualRefreshPath() async throws {
        try await withWorld { url, resources in
            #expect(resources.players.first?.health == 4)
            try writeLevel(url, health: 12)
            let read: [PlayerInfo]? = await WorldResources.readPlayers(resources.world)
            #expect(read?.first?.health == 12)
            resources.worldChanged([url.appendingPathComponent("level.dat")])
            await resources.waitForRefresh()
            #expect(resources.players.first?.health == 12)
            #expect(resources.players.first?.position?.x == 12)
        }
    }

    @Test func anUnreadableAtomicSaveRetainsPlayersButALegitimateEmptySaveClearsThem() async throws {
        try await withWorld { url, resources in
            let first = WorldSession(resources: resources)
            let second = WorldSession(resources: resources)
            defer { first.close(); second.close() }
            let original = resources.playerSnapshot
            let level = url.appendingPathComponent("level.dat")
            try Data([0xFF]).write(to: level, options: .atomic)
            resources.worldChanged([level])
            await resources.waitForRefresh()
            #expect(resources.players.first?.health == 4)
            #expect(resources.playerSnapshot === original)
            #expect(first.search.playerSnapshot === original && second.search.playerSnapshot === original)
            try writeLevel(url, health: nil)
            resources.worldChanged([level])
            await resources.waitForRefresh()
            #expect(resources.players.isEmpty)
            #expect(resources.playerSnapshot !== original)
            #expect(first.search.playerSnapshot === resources.playerSnapshot)
            #expect(second.search.playerSnapshot === resources.playerSnapshot)
        }
    }
}
