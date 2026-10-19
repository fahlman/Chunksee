import ChunkseeKit
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionNameTests {
    private func world(_ customIDs: [String]) throws -> URL {
        let url = try TestWorld.make(chunks: [])
        for id in customIDs {
            let folder = id.replacingOccurrences(of: ":", with: "/")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/\(folder)/region"),
                                                     withIntermediateDirectories: true)
        }
        return url
    }

    private func session(_ url: URL) async throws -> WorldSession {
        let defaults = TestDefaults.make()
        return try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
    }

    @Test func collidingCustomLabelsKeepTheirFullIdentity() async throws {
        let ids = ["mod_a:caves", "mod_b:caves", "mod_a:cave_realm", "mod_a:cave__realm", "mod_a:sky_realm"]
        let url = try world(ids)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await session(url)
        #expect(Set(session.dimensions.map(\.id)) == Set(ids + ["minecraft:overworld"]))
        #expect(session.presentation.dimensionName("mod_a:caves") == "Caves (mod_a:caves)")
        #expect(session.presentation.dimensionName("mod_b:caves") == "Caves (mod_b:caves)")
        #expect(session.presentation.dimensionName("mod_a:cave_realm") == "Cave Realm (mod_a:cave_realm)")
        #expect(session.presentation.dimensionName("mod_a:cave__realm") == "Cave Realm (mod_a:cave__realm)")
        #expect(session.presentation.dimensionName("mod_a:sky_realm") == "Sky Realm")
        #expect(session.presentation.dimensionName("minecraft:overworld") == "Overworld")
        #expect(Set(session.dimensions.map { session.presentation.dimensionName($0.id) }).count == session.dimensions.count)
        // A player's location can refer to a dimension absent from this world's current folders.
        #expect(session.presentation.dimensionName("mod_b:sky_realm") == "Sky Realm (mod_b:sky_realm)")
        #expect(session.presentation.dimensionName("unavailable:void_realm") == "Void Realm")
        #expect(session.presentation.dimensionName("minecraft:the_end") == "The End")
        session.close()
        await session.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1)))
    func liveLabelsUpdateWithoutRetainingTheDocument() async throws {
        let url = try world(["mod_a:caves"])
        defer { try? FileManager.default.removeItem(at: url) }
        var document: WorldSession? = try await session(url)
        defer { document?.close() }
        let presentation = try #require(document?.presentation)
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        defer { continuation.finish() }
        var iterator = updates.makeAsyncIterator()
        let initial = withObservationTracking {
            presentation.dimensionName("mod_a:caves")
        } onChange: { continuation.yield(true) }
        #expect(initial == "Caves")

        // Opening another dimension can change an existing window's collision-safe title.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/mod_b/caves/region"),
                                                 withIntermediateDirectories: true)
        let snapshot = try await WorldSnapshot.read(url)
        document?.resources.includeDimensions(from: snapshot)
        snapshot.access.release()
        let changed = await iterator.next(isolation: #isolation)
        #expect(changed == true)
        #expect(presentation.dimensionName("mod_a:caves") == "Caves (mod_a:caves)")
        #expect(presentation.dimensionName("mod_b:caves") == "Caves (mod_b:caves)")
        document?.close()
        await document?.waitUntilClosed()
        weak let released = document
        document = nil
        #expect(released == nil)
        #expect(presentation.selectedDimension == nil && presentation.listedPlayers.isEmpty)
    }

    @Test func customLabelsCannotHideWhichVanillaDimensionTheyMatch() async throws {
        let url = try world(["example:overworld"])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await session(url)
        #expect(session.presentation.dimensionName("minecraft:overworld") == "Overworld (minecraft:overworld)")
        #expect(session.presentation.dimensionName("example:overworld") == "Overworld (example:overworld)")
        session.close()
        await session.waitUntilClosed()
    }
}
