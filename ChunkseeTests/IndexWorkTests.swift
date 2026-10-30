import ChunkseeIndex
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct IndexWorkTests {
    @Test(.timeLimit(.minutes(1))) func eachDimensionPublishesBeforeTheInitialWorldPassFinishes() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"), withIntermediateDirectories: true)
        let world = try World(contentsOf: url)
        let overworld = try #require(world.dimension("overworld")), nether = try #require(world.dimension("the_nether"))
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionContent>()
        let index = WorldIndexStore(readers: [RegionReader(dimension: nether, cache: .off), RegionReader(dimension: overworld, cache: .off)],
            work: work, firstDimension: overworld.id, playerRoster: PlayerRoster([]),
            readDimension: { reader, _, _ in await gate.read(reader.dimension.id) })
        await gate.waitForRequest(overworld.id)
        #expect(index.isIndexing && index.index.dimensions.isEmpty)
        await gate.finish(overworld.id, with: DimensionContent())
        await gate.waitForRequest(nether.id)
        #expect(index.index.dimensions[overworld.id] != nil && index.index.dimensions[nether.id] == nil)
        #expect(index.isIndexing && index.isWaitingForPortals(in: nether.id))
        #expect(!index.isWaitingForPortals(in: overworld.id))
        await gate.finish(nether.id, with: DimensionContent())
        await index.waitForIndex()
        #expect(Set(index.index.dimensions.keys) == [overworld.id, nether.id] && !index.isIndexing)
        index.cancel(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func replacementReadersCanFinishBeforeRetiredReadsDrain() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        var old: RegionReader? = RegionReader(dimension: dimension, cache: .off)
        weak let retired = old
        let current = RegionReader(dimension: dimension, cache: .off)
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionContent>(), numbers = ReadNumbers()
        let index = WorldIndexStore(readers: old.map { [$0] } ?? [], work: work, firstDimension: nil, playerRoster: PlayerRoster([]),
            readDimension: { _, _, _ in await gate.read(String(await numbers.next())) })
        await gate.waitForRequest("0")
        index.replace(readers: [current], firstDimension: nil)
        old = nil
        await gate.waitForCancellation("0"); await gate.waitForRequest("1")
        await gate.finish("1", with: DimensionContent())
        await index.waitForIndex()
        #expect(index.index.dimensions[dimension.id] != nil && !index.isIndexing)
        let revision = index.revision
        #expect(retired != nil)
        await gate.finish("0", with: DimensionContent())
        await index.waitForTasks()
        #expect(index.revision == revision && index.readers.first === current)
        #expect(retired == nil)
        index.cancel(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func worldOwnerCloseDropsQueuedWorkAndLateIndexResults() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionContent>()
        let index = WorldIndexStore(readers: [RegionReader(dimension: dimension, cache: .off)], work: work, firstDimension: nil, playerRoster: PlayerRoster([]),
                                    readDimension: { _, _, _ in await gate.read("index") })
        await gate.waitForRequest("index")
        index.rebuild(firstDimension: nil)
        work.close()
        await gate.waitForCancellation("index")
        await gate.finish("index", with: DimensionContent())
        await work.waitUntilFinished()
        await index.waitForIndex()
        #expect(index.index.dimensions.isEmpty && !index.isIndexing && index.revision == 0)
        index.rebuild(firstDimension: nil)
        await index.waitForTasks()
        #expect(await gate.requested == ["index"])
        index.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneIndexDrainsOnlyItsOwnWork() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionContent>()
        let first = WorldIndexStore(readers: [reader], work: work, firstDimension: nil, playerRoster: PlayerRoster([]),
                                    readDimension: { _, _, _ in await gate.read("first") })
        let second = WorldIndexStore(readers: [reader], work: work, firstDimension: nil, playerRoster: PlayerRoster([]),
                                     readDimension: { _, _, _ in await gate.read("second") })
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.cancel()
        await gate.waitForCancellation("first")
        await gate.finish("first", with: DimensionContent())
        await first.waitForTasks() // Must return while the other index is still held.
        #expect(first.index.dimensions.isEmpty && !work.isClosed)
        await gate.finish("second", with: DimensionContent())
        await second.waitForIndex()
        #expect(second.index.dimensions[dimension.id] != nil && second.revision == 1)
        second.cancel()
        work.close()
        await work.waitUntilFinished()
    }
}
