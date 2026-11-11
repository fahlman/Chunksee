import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct LiveDimensionCatalogTests {
    private final class Fixture {
        let url: URL
        let defaults: UserDefaults
        let model: AppModel
        var sessions: [WorldSession] = []
        var resources: [WorldResources] = []
        var gates: [AsyncReadGate<RegionFacts>] = []
        let emptyFacts: RegionFacts

        init() throws {
            emptyFacts = try TestWorld.facts()
            let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            url = try TestWorld.make(chunks: [chunk])
            defaults = TestDefaults.make()
            model = AppModel(defaults: defaults, cacheRoot: nil)
            try model.worldFolders.remember(url)
        }

        func open(_ document: URL) async throws -> WorldSession {
            let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
            guard case .dimension(let snapshot) = try await reader.readFolder(document) else { throw WorldOpenError.notADimension }
            let session = try await snapshot.makeSession(in: model)
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

        func blockedIndex() async throws -> (WorldResources, AsyncReadGate<RegionFacts>, Reads) {
            let gate = AsyncReadGate<RegionFacts>(), calls = Reads()
            let resource = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: model.names,
                savedSearches: model.savedSearches, defaults: defaults, cacheRoot: nil, readRegion: { dimension, region, options in
                    let count = await calls.next(dimension.id)
                    if dimension.id == "minecraft:overworld", count == 0 { return await gate.read("overworld") }
                    return try await RegionReader.scan(dimension, region: region, options: options)
                })
            resources.append(resource)
            gates.append(gate)
            await gate.waitForRequest("overworld")
            return (resource, gate, calls)
        }

        func close() async {
            for gate in gates { await gate.finishAll(with: emptyFacts) }
            sessions.forEach { $0.close() }
            resources.forEach { $0.close() }
            for session in sessions { await session.waitUntilClosed() }
            for resource in resources { await resource.waitUntilClosed() }
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
            first.navigation.goToCoordinates(CGPoint(x: 101, y: -202))
            first.visibility.showsGrid = true
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
            // Including a dimension also refreshes definitions and players. Settle that
            // publication before taking the baseline for a later repeated document opening.
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            #expect(resources.index.index.dimensions["minecraft:the_nether"]?.places.filter { $0.group == .spawner }.count == 1)
            #expect(first.map === oldMap && oldMap.viewport == view)
            #expect(first.visibility.showsGrid && !second.visibility.showsGrid && first.navigation.canGoBack)

            let reader = resources.readers["minecraft:the_nether"], revision = resources.index.revision
            let repeated = try await f.open(folder)
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            #expect(repeated.map != nil && repeated.resources === resources)
            #expect(resources.readers.count == 2 && resources.readers["minecraft:the_nether"] === reader)
            #expect(resources.index.revision == revision)
        }
    }

    @Test func twoNewDocumentsKeepOneCanonicalCatalogAndAnOlderSnapshotCannotPruneIt() async throws {
        try await withFixture { f in
            let first = try await f.open(f.url.appendingPathComponent("dimensions/minecraft/overworld"))
            let resources = first.resources, oldReader = resources.readers["minecraft:overworld"]
            let oldSnapshot = try await WorldSnapshot.read(f.url)
            let nether = try f.addDimension("the_nether"), end = try f.addDimension("the_end")
            let secondTask = Task { try await f.open(nether) }
            let thirdTask = Task { try await f.open(end) }
            let second = try await secondTask.value, third = try await thirdTask.value
            #expect(second.map != nil && third.map != nil)
            #expect(second.resources === resources && third.resources === resources)
            #expect(try await f.model.resources(for: oldSnapshot) === resources)
            #expect(Set(resources.dimensions.map(\.id)) == ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"])
            #expect(resources.readers["minecraft:overworld"] === oldReader)
            await resources.index.waitForIndex()
            #expect(Set(resources.index.index.dimensions.keys) == Set(resources.dimensions.map(\.id)))
            second.close()
            await second.waitUntilClosed()
            #expect(!resources.isClosed && third.map != nil && first.map != nil)
        }
    }

    @Test func additionsDuringAnUnfinishedPassAccumulateWithoutReplacingReadersOrCancelingIt() async throws {
        try await withFixture { f in
            let (resources, gate, _) = try await f.blockedIndex()
            let oldReader = resources.readers["minecraft:overworld"]
            for name in ["the_nether", "the_end"] {
                _ = try f.addDimension(name)
                let snapshot = try await WorldSnapshot.read(f.url)
                try await resources.includeDimensions(from: snapshot)
                snapshot.access.release()
            }
            #expect(resources.readers.count == 3 && resources.readers["minecraft:overworld"] === oldReader)
            #expect(resources.index.isIndexing)
            await gate.finish("overworld", with: try TestWorld.facts())
            await resources.index.waitForIndex()
            #expect(Set(resources.index.index.dimensions.keys) == Set(resources.dimensions.map(\.id)))
            for id in ["minecraft:the_nether", "minecraft:the_end"] {
                #expect(resources.index.index.dimensions[id]?.places.filter { $0.group == .spawner }.count == 1)
            }
        }
    }

    @Test func closingDrainsTheExistingReadAndDropsQueuedNewDimensions() async throws {
        try await withFixture { f in
            let (resources, gate, calls) = try await f.blockedIndex()
            _ = try f.addDimension("the_nether")
            let snapshot = try await WorldSnapshot.read(f.url)
            try await resources.includeDimensions(from: snapshot)
            snapshot.access.release()
            resources.close()
            await gate.waitForCancellation("overworld")
            await gate.finish("overworld", with: try TestWorld.facts())
            await resources.waitUntilClosed()
            #expect(await calls.counts["minecraft:the_nether"] == nil)
            #expect(resources.index.index.dimensions.isEmpty && !resources.index.isIndexing)

            _ = try f.addDimension("the_end")
            let afterClose = try await WorldSnapshot.read(f.url)
            try await resources.includeDimensions(from: afterClose)
            afterClose.access.release()
            #expect(resources.isClosed && resources.readers.count == 2)
        }
    }

    @Test func invalidFoldersCannotGrowTheCatalogAndTheNewDimensionReceivesLiveUpdates() async throws {
        try await withFixture { f in
            let first = try await f.open(f.url.appendingPathComponent("dimensions/minecraft/overworld"))
            let resources = first.resources
            let invalid = f.url.appendingPathComponent("dimensions/minecraft/not_a_dimension")
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            await #expect(throws: WorldOpenError.notADimension) { try await f.open(invalid) }
            #expect(resources.readers.count == 1 && !resources.isClosed)
            let folder = try f.addDimension("the_nether")
            let second = try await f.open(folder)
            await resources.index.waitForIndex()
            let file = folder.appendingPathComponent("region/r.0.0.mca")
            try Data(TestWorld.regionFile([])).write(to: file)
            resources.refreshDelay = .zero
            resources.worldChanged([file])
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            #expect(second.map != nil && resources.index.index.dimensions["minecraft:the_nether"]?.places.isEmpty == true)
            #expect(resources.index.index.dimensions["minecraft:overworld"]?.formats.readable == 1)
        }
    }

    private actor Reads {
        private(set) var counts: [String: Int] = [:]
        func next(_ dimension: String) -> Int {
            let count = counts[dimension, default: 0]
            counts[dimension] = count + 1
            return count
        }
    }
}
