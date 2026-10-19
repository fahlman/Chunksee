import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionRefreshTests {
    private let ids = ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]

    private func world() throws -> URL {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        for folder in ["DIM-1", "DIM1"] {
            let target = url.appendingPathComponent(folder + "/region")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(TestWorld.regionFile([chunk])).write(to: target.appendingPathComponent("r.0.0.mca"))
        }
        return url
    }

    @Test func liveRefreshDoesNotReadUnchangedDimensionsAndKeepsTheirContents() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = RegionReads()
        let defaults = TestDefaults.make()
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       readRegion: { dimension, _ in try await reads.read(dimension.id) })
        resources.refreshDelay = .zero
        await resources.index.waitForIndex()
        #expect(Set(await reads.requested) == Set(ids))
        #expect(Set(resources.index.index.dimensions.keys) == Set(ids))
        let initial = resources.index.index.dimensions.mapValues { $0.storage.first?.count }
        let overworld = try #require(resources.dimensions.first { $0.id == ids[0] })
        await reads.reset(changing: ids[0])
        resources.worldChanged([overworld.regionDirectory.appendingPathComponent("r.0.0.mca")])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(Set(await reads.requested) == [ids[0]])
        let updated = resources.index.index.dimensions.mapValues { $0.storage.first?.count }
        #expect(updated[ids[0]] != initial[ids[0]])
        #expect(updated[ids[1]] == initial[ids[1]] && updated[ids[2]] == initial[ids[2]])
        #expect(Set(resources.index.index.dimensions.keys) == Set(ids))
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func broadDirectoryNotificationsRouteToTheAppropriateReaders() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = RegionReads()
        let defaults = TestDefaults.make()
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       readRegion: { dimension, _ in try await reads.read(dimension.id) })
        resources.refreshDelay = .zero
        await resources.index.waitForIndex()
        let nether = try #require(resources.dimensions.first { $0.id == ids[1] })
        await reads.reset()
        resources.worldChanged([nether.url])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(Set(await reads.requested) == [ids[1]])
        await reads.reset()
        resources.worldChanged([url])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(Set(await reads.requested) == Set(ids))
        await reads.reset()
        resources.worldChanged([resources.world.playerDataDirectory])
        await resources.waitForRefresh()
        await resources.index.waitForIndex()
        #expect(await reads.requested.isEmpty)
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func queuedChangesAccumulateAndFullRequestsDominate(full: Bool) async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimensions = try World(contentsOf: url).dimensions()
        let readers = try ids.map { id in RegionReader(dimension: try #require(dimensions.first { $0.id == id }), cache: .off) }
        let gate = AsyncReadGate<DimensionIndex>()
        let index = WorldIndexStore(readers: readers, firstDimension: nil,
                                    readDimension: { reader, _, _ in await gate.read(reader.dimension.id) })
        await gate.waitForRequest(ids[0])
        index.rebuild(firstDimension: nil, changes: [ids[0]: .all])
        if full { index.rebuild(firstDimension: nil) }
        index.rebuild(firstDimension: nil, changes: [ids[1]: .all])
        for id in ids {
            await gate.waitForRequest(id)
            await gate.finish(id, with: DimensionIndex())
        }
        let queued = full ? ids : Array(ids.prefix(2))
        for id in queued {
            await gate.waitForRequest(id, count: 2)
            await gate.finish(id, with: DimensionIndex())
        }
        await index.waitForIndex()
        #expect(await gate.requested == ids + queued)
        #expect(Set(index.index.dimensions.keys) == Set(ids))
        #expect(!index.isIndexing)
        index.cancel()
        await index.waitForTasks()
    }

    @Test(.timeLimit(.minutes(1))) func closingDropsQueuedSubsetAndPreventsLatePublication() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let gate = AsyncReadGate<DimensionIndex>()
        let index = WorldIndexStore(readers: [RegionReader(dimension: dimension, cache: .off)], firstDimension: nil,
                                    readDimension: { reader, _, _ in await gate.read(reader.dimension.id) })
        await gate.waitForRequest(ids[0])
        index.rebuild(firstDimension: nil, changes: [ids[0]: .all])
        index.cancel()
        await gate.waitForCancellation(ids[0])
        await gate.finish(ids[0], with: DimensionIndex())
        await index.waitForTasks()
        await index.waitForIndex()
        #expect(await gate.requested == [ids[0]])
        #expect(index.index.dimensions.isEmpty && !index.isIndexing)
    }

    private actor RegionReads {
        private(set) var requested: [String] = []
        private var versions: [String: Int32] = [:]

        func reset(changing dimension: String? = nil) {
            requested = []
            if let dimension { versions[dimension, default: 1] += 1 }
        }

        func read(_ dimension: String) throws -> RegionFacts {
            requested.append(dimension)
            return try TestWorld.facts(dimensionID: dimension, blockEntities: [.compound([
                "id": .string("minecraft:chest"), "x": .int(1), "y": .int(64), "z": .int(2),
                "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(versions[dimension] ?? 1)])]),
            ])])
        }
    }
}
