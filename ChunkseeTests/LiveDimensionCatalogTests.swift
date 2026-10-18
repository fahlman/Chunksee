import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import Chunksee

@Suite(.timeLimit(.minutes(1))) struct LiveDimensionCatalogTests {
    private final class Fixture {
        let url: URL
        let suite: String
        let defaults: UserDefaults
        let model: AppModel
        var sessions: [WorldSession] = []

        init() throws {
            let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            url = try TestWorld.make(chunks: [chunk])
            suite = "ChunkseeTests-\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            model = AppModel(defaults: defaults, cacheRoot: nil)
            model.worldFolders.remember(url)
        }

        func open(_ document: URL) async throws -> WorldSession {
            let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
            guard case .dimension(let snapshot) = try await reader.readContents(from: document) else { throw WorldOpenError.notADimension }
            let session = try snapshot.makeSession(in: model)
            sessions.append(session)
            return session
        }

        func addDimension(_ name: String) throws -> URL {
            let folder = url.appendingPathComponent("dimensions/minecraft/\(name)")
            let region = folder.appendingPathComponent("region")
            try FileManager.default.createDirectory(at: region, withIntermediateDirectories: true)
            var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            if case .compound(var values) = chunk.nbt {
                values["block_entities"] = .list([.compound(["id": .string("minecraft:mob_spawner"),
                    "x": .int(8), "y": .int(2), "z": .int(8),
                    "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])])])])
                chunk.nbt = .compound(values)
            }
            try Data(TestWorld.regionFile([chunk])).write(to: region.appendingPathComponent("r.0.0.mca"))
            return folder
        }

        func close() async {
            sessions.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func openingANewlyCreatedDimensionExtendsTheExistingWorldWithoutReplacingItsTab() async throws {
        try await withFixture { f in
            let first = try await f.open(f.url.appendingPathComponent("dimensions/minecraft/overworld"))
            let resources = first.resources, oldMap = try #require(first.map)
            await resources.index.waitForIndex()
            first.goToCoordinates(CGPoint(x: 101, y: -202))
            first.visibility.showsGrid = false
            let view = oldMap.viewport
            #expect(first.navigation.canGoBack)

            let folder = try f.addDimension("the_nether")
            let second = try await f.open(folder)
            #expect(second.resources === resources)
            #expect(second.selectedDimensionID == "minecraft:the_nether")
            #expect(second.map != nil)
            #expect(resources.dimensions.map(\.id) == ["minecraft:overworld", "minecraft:the_nether"])
            #expect(resources.readers["minecraft:the_nether"] != nil)
            #expect(resources.dimensionDocuments[folder.resolvingSymlinksInPath().path] == "minecraft:the_nether")
            await resources.index.waitForIndex()
            #expect(resources.index.index.dimensions["minecraft:the_nether"]?.contents.spawners.count == 1)
            #expect(first.map === oldMap && oldMap.viewport == view)
            #expect(!first.visibility.showsGrid && first.navigation.canGoBack)
        }
    }
}
