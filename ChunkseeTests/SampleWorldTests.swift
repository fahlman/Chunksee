import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct SampleWorldTests {
    @Test func bundledWorldOpensIndexesSearchesAndRendersWithoutChangingFiles() async throws {
        let url = try #require(SampleWorld.url(in: .main))
        let before = try files(in: url)
        let defaults = TestDefaults.make()
        let app = AppModel(defaults: defaults, cacheRoot: nil)
        let reader = WorldDocument.Reader(folders: app.worldFolders, model: app)
        guard case .world(let dimensions) = try await reader.readFolder(url) else {
            Issue.record("The bundled folder must open through the ordinary world-document reader")
            return
        }
        #expect(dimensions.count == 1)
        let dimensionURL = try #require(dimensions.first)
        guard case .dimension(let snapshot) = try await reader.readFolder(dimensionURL) else {
            Issue.record("The sample's dimension must open through its remembered world folder")
            return
        }
        let session = try snapshot.makeSession(in: app)
        defer { session.close() }
        await session.search.waitForIndex()
        #expect(session.selectedDimensionID == "minecraft:overworld")
        #expect(session.selectedIndex.formats.readable == 256)
        #expect(session.players.count == 1)
        let pets = session.selectedIndex.creatures.map(\.creature)
        #expect(Set(pets.compactMap(\.customName)) == ["Scout", "Socks"])
        #expect(pets.allSatisfy { $0.owner == session.players.first?.uuid })
        #expect(session.selectedIndex.places.filter { $0.group == .spawner }.map(\.mob) == ["minecraft:zombie"])
        session.search.text = "diamond"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        #expect(session.search.results.count == 1 && hit.count == 12)
        #expect(hit.position == CGPoint(x: 93.5, y: 109.5) && hit.y == 58)
        let dimension = try #require(session.selectedDimension)
        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: .init(x: 0, z: 0)))
        #expect(pixels.count == 512 * 512 * 4)
        #expect(stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] != 0 }.count == 256 * 256)
        session.close()
        await session.waitUntilClosed()
        #expect(try files(in: url) == before)
    }

    @Test func bundledDataMatchesItsOriginalContentRecipe() throws {
        let bundled = try #require(SampleWorld.url(in: .main))
        let generated = try SampleWorldFixture.make()
        defer { try? FileManager.default.removeItem(at: generated) }
        let expected = try files(in: generated)
        var actual = try files(in: bundled)
        actual["README.md"] = nil
        #expect(actual == expected)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
