import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct IndexWorkTests {
    @Test(.timeLimit(.minutes(1))) func worldOwnerCloseDropsQueuedWorkAndLateIndexResults() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionIndex>()
        let index = WorldIndexStore(readers: [RegionReader(dimension: dimension, cache: .off)], work: work, firstDimension: nil,
                                    readDimension: { _, _, _ in await gate.read("index") })
        await gate.waitForRequest("index")
        index.rebuild(firstDimension: nil)
        work.close()
        await gate.waitForCancellation("index")
        await gate.finish("index", with: DimensionIndex())
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
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionIndex>()
        let first = WorldIndexStore(readers: [reader], work: work, firstDimension: nil,
                                    readDimension: { _, _, _ in await gate.read("first") })
        let second = WorldIndexStore(readers: [reader], work: work, firstDimension: nil,
                                     readDimension: { _, _, _ in await gate.read("second") })
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.cancel()
        await gate.waitForCancellation("first")
        await gate.finish("first", with: DimensionIndex())
        await first.waitForTasks() // Must return while the other index is still held.
        #expect(first.index.dimensions.isEmpty && !work.isClosed)
        await gate.finish("second", with: DimensionIndex())
        await second.waitForIndex()
        #expect(second.index.dimensions[dimension.id] != nil && second.revision == 1)
        second.cancel()
        work.close()
        await work.waitUntilFinished()
    }
}
