import Foundation
import ChunkseeKit
@testable import ChunkseeTestHost
import Testing

@Suite(.isolatedStores)
struct RefreshLoaderTests {
    @Test(.timeLimit(.minutes(1))) func refreshesCoalesceAndHiddenInvalidationSurvives() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("value") }
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(isEnabled: true, reread: true)
        loader.request(isEnabled: true, reread: true)
        await gate.finish("value", with: 1)
        await gate.waitForRequest("value", count: 2)
        #expect(loader.value == 1)
        await gate.finish("value", with: 2)
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        #expect(await gate.requested == ["value", "value"])

        loader.request(isEnabled: false, reread: true)
        #expect(await gate.requested.count == 2)
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value", count: 3)
        #expect(loader.value == 2)
        await gate.finish("value", with: 3)
        await loader.waitUntilFinished()
        #expect(loader.value == 3)
        loader.close()
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWaiterDoesNotCancelTheSharedRead() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("value") }
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task {
                started.resume()
                await loader.waitUntilFinished()
            }
        }
        waiter?.cancel()
        await gate.finish("value", with: 7)
        await waiter?.value
        #expect(loader.value == 7)
        #expect(await gate.requested == ["value"])
        loader.close()
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneLoaderKeepsItsSiblingAndRejectsLateResults() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let first = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("first") }
        let second = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("second") }
        first.request(isEnabled: true, reread: false)
        second.request(isEnabled: true, reread: false)
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.request(isEnabled: true, reread: true)
        first.close()
        await gate.waitForCancellation("first")
        #expect(!work.isClosed)
        await gate.finish("first", with: 1)
        await gate.finish("second", with: 2)
        await work.waitUntilFinished()
        #expect(first.value == nil && second.value == 2)
        #expect(await gate.requested.count == 2)
        first.request(isEnabled: true, reread: true)
        #expect(await gate.requested.count == 2)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingBeforeEntryStillDrainsTheLoader() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        await gate.releaseAllAndFuture(with: 1)
        let loader = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("value") }
        loader.request(isEnabled: true, reread: false)
        loader.close()
        await loader.waitUntilFinished()
        #expect(loader.value == nil)
        #expect(await gate.requested.isEmpty)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func drainingIncludesWorkRegisteredDuringTheWait() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Void>()
        work.start(priority: .utility) {
            await gate.read("first")
            work.start(priority: .utility) { await gate.read("second") }
        }
        await gate.waitForRequest("first")
        var finished = false
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { started in
            waiter = Task {
                started.resume()
                await work.waitUntilFinished()
                finished = true
            }
        }
        await gate.finish("first", with: ())
        await gate.waitForRequest("second")
        #expect(!finished)
        await gate.finish("second", with: ())
        await waiter?.value
        #expect(finished)
        work.close()
        #expect(work.start(priority: .utility) {} == nil)
    }

    @Test(.timeLimit(.minutes(1))) func hidingDuringAReadDefersItsQueuedRefreshUntilShown() async {
        let work = BackgroundWork(), gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: work, priority: .utility) { _ in await gate.read("value") }
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(isEnabled: true, reread: true)
        loader.request(isEnabled: false, reread: false)
        await gate.finish("value", with: 1)
        await loader.waitUntilFinished()
        #expect(loader.value == 1)
        #expect(await gate.requested.count == 1)
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value", count: 2)
        await gate.finish("value", with: 2)
        await loader.waitUntilFinished()
        #expect(loader.value == 2)
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func worldClosureDrainsRegisteredWorkAndPreventsPublication() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       watchWorld: { _, _ in nil })
        await resources.index.waitForIndex()
        let gate = AsyncReadGate<Int>()
        let loader = RefreshLoader(work: resources.backgroundWork, priority: .utility) { _ in await gate.read("value") }
        loader.request(isEnabled: true, reread: false)
        await gate.waitForRequest("value")
        loader.request(isEnabled: true, reread: true)
        var finishedClosing = false
        let closing = Task {
            resources.close()
            await resources.waitUntilClosed()
            finishedClosing = true
        }
        await gate.waitForCancellation("value")
        #expect(resources.isClosed && resources.backgroundWork.isClosed && !finishedClosing)
        await gate.finish("value", with: 9)
        await closing.value
        #expect(finishedClosing && loader.value == nil)
        loader.request(isEnabled: true, reread: true)
        #expect(await gate.requested == ["value"])
    }
}
