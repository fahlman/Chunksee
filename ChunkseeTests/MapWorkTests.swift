import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct MapWorkTests {
    @Test(.timeLimit(.minutes(1))) func worldClosureWaitsForARenderInAnAlreadyClosedTab() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk]), defaults = TestDefaults.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let opening = try resources.opening()
        let render = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let tab = WorldSession(resources: resources, renderTile: { _, _ in await render.read("render") })
        let map = try #require(tab.map)
        map.viewport.center = CGPoint(x: 8, y: 8)
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        await render.waitForRequest("render")
        tab.close()
        await render.waitForCancellation("render")
        #expect(tab.isClosed && !resources.isClosed)
        // The last document opening finishes after this tab detached. The common owner must
        // retain its canceled render, even though no live session remains in WorldResources.
        opening.finish()
        var finishedReads = false
        let draining = Task.immediate {
            await resources.backgroundWork.waitUntilFinished()
            finishedReads = true
        }
        var finishedClosing = false
        let closing = Task.immediate {
            await resources.waitUntilClosed()
            finishedClosing = true
        }
        #expect(resources.isClosed && !finishedReads && !finishedClosing)
        await render.finish("render", with: nil)
        await draining.value
        await closing.value
        await tab.waitUntilClosed()
        #expect(finishedReads && finishedClosing && map.tiles.isEmpty && !map.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureCancelsMapReadsAndRejectsLatePixelsAndCopies() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let image = try #require(CGImage.rgba([255, 255, 255, 255], width: 1, height: 1))
        let tile = RegionTileRenderer.RenderedTile(full: image, preview: image)
        let render = AsyncReadGate<RegionTileRenderer.RenderedTile?>(), columns = AsyncReadGate<MapModel.TopBlockRead?>()
        let work = BackgroundWork()
        let map = MapModel(work: work, dimension: dimension, center: CGPoint(x: 8, y: 8),
                           renderTile: { _, _ in await render.read("render") },
                           readTopBlocks: { chunk, _, _ in await columns.read("\(chunk.x)") })
        var copied = false
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        map.readTopBlock(at: CGPoint(x: 17, y: 1)) { _ in copied = true }
        await render.waitForRequest("render")
        await columns.waitForRequest("0")
        await columns.waitForRequest("1")
        #expect(map.unfinishedHoverReads == 1 && map.unfinishedCoordinateReads == 1)
        work.close()
        await render.waitForCancellation("render")
        await columns.waitForCancellation("0")
        await columns.waitForCancellation("1")
        await render.finish("render", with: tile)
        await columns.finish("0", with: nil)
        await columns.finish("1", with: nil)
        await work.waitUntilFinished()
        await map.waitForRenders()
        #expect(map.tiles.isEmpty && map.previews.isEmpty && !map.isLoading && !copied)
        #expect(map.unfinishedHoverReads == 0 && map.unfinishedCoordinateReads == 0)
        map.requestTiles(visibleIn: CGSize(width: 20, height: 20))
        map.loadTopBlocks(at: CGPoint(x: 32, y: 0))
        map.readTopBlock(at: CGPoint(x: 32, y: 0)) { _ in copied = true }
        await map.waitForRenders()
        #expect(await render.requested == ["render"])
        #expect(Set(await columns.requested) == ["0", "1"])
        #expect(!copied)
        map.close()
    }

    @Test(.timeLimit(.minutes(1))) func combinedDrainIncludesNewWorkWithoutWaitingForAnotherConsumer() async {
        let work = BackgroundWork(), first = work.makeScope(), second = work.makeScope(), unrelated = work.makeScope()
        let gate = AsyncReadGate<Void>()
        unrelated.start(priority: .utility) { await gate.read("unrelated") }
        second.start(priority: .utility) {
            await gate.read("second")
            first.start(priority: .utility) { await gate.read("first") }
        }
        await gate.waitForRequest("unrelated")
        await gate.waitForRequest("second")
        #expect(first.unfinishedCount == 0 && second.unfinishedCount == 1)
        var finished = false
        let draining = Task.immediate {
            await work.waitUntilFinished(in: [first, second])
            finished = true
        }
        #expect(!finished)
        await gate.finish("second", with: ())
        await gate.waitForRequest("first")
        #expect(!finished && first.unfinishedCount == 1)
        await gate.finish("first", with: ())
        await draining.value // The unrelated scope is deliberately still held.
        #expect(finished && first.unfinishedCount == 0 && second.unfinishedCount == 0)
        #expect(unrelated.unfinishedCount == 1)
        work.close()
        await gate.waitForCancellation("unrelated")
        await gate.finish("unrelated", with: ())
        await work.waitUntilFinished()
    }
}
