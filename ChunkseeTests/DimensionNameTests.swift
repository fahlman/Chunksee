import ChunkseeKit
import Foundation
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
        #expect(session.dimensionName("mod_a:caves") == "Caves (mod_a:caves)")
        #expect(session.dimensionName("mod_b:caves") == "Caves (mod_b:caves)")
        #expect(session.dimensionName("mod_a:cave_realm") == "Cave Realm (mod_a:cave_realm)")
        #expect(session.dimensionName("mod_a:cave__realm") == "Cave Realm (mod_a:cave__realm)")
        #expect(session.dimensionName("mod_a:sky_realm") == "Sky Realm")
        #expect(session.dimensionName("minecraft:overworld") == "Overworld")
        #expect(Set(session.dimensions.map { session.dimensionName($0.id) }).count == session.dimensions.count)
        // A player's location can refer to a dimension absent from this world's current folders.
        #expect(session.dimensionName("mod_b:sky_realm") == "Sky Realm (mod_b:sky_realm)")
        #expect(session.dimensionName("unavailable:void_realm") == "Void Realm")
        #expect(session.dimensionName("minecraft:the_end") == "The End")
        session.close()
        await session.waitUntilClosed()
    }

    @Test func customLabelsCannotHideWhichVanillaDimensionTheyMatch() async throws {
        let url = try world(["example:overworld"])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await session(url)
        #expect(session.dimensionName("minecraft:overworld") == "Overworld (minecraft:overworld)")
        #expect(session.dimensionName("example:overworld") == "Overworld (example:overworld)")
        session.close()
        await session.waitUntilClosed()
    }
}
