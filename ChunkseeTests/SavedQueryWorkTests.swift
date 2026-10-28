import ChunkseeIndex
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct SavedQueryWorkTests {
    private func request() -> SearchRequest {
        SearchRequest(queries: ["saved"], index: SearchIndex(), players: [], playerNames: [:], gameNames: .unavailable)
    }
    private func sources() -> SearchSources {
        SearchSources(names: [:], playerSnapshot: PlayerSnapshot([]), indexRevision: 0)
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureDrainsLateReadsAndRejectsTheirResults() async {
        let work = BackgroundWork(), cache = SavedQueryResults(work: work)
        let gate = AsyncReadGate<SavedQueryResults.Results>()
        let request = request(), sources = sources()
        let pending = Task.immediate {
            await cache.results(for: request, sources: sources, waiter: UUID(),
                                execute: { _ in await gate.read("saved") })
        }
        await gate.waitForRequest("saved")
        work.close()
        await gate.waitForCancellation("saved")
        var drained = false
        let closing = Task.immediate { await work.waitUntilFinished(); drained = true }
        #expect(!drained)
        await gate.finish("saved", with: ["saved": []])
        #expect(await pending.value == nil)
        await closing.value
        #expect(drained)
        let after = await cache.results(for: request, sources: sources, waiter: UUID(),
                                        execute: { _ in await gate.read("after") })
        #expect(after == nil)
        #expect(await gate.requested == ["saved"])
    }

    @Test(.timeLimit(.minutes(1))) func localCancellationReleasesWaitersAndLeavesAnotherConsumerRunning() async {
        let work = BackgroundWork(), first = SavedQueryResults(work: work), second = SavedQueryResults(work: work)
        let gate = AsyncReadGate<SavedQueryResults.Results>()
        let request = request(), sources = sources()
        let firstWaiter = Task.immediate {
            await first.results(for: request, sources: sources, waiter: UUID(),
                                execute: { _ in await gate.read("first") })
        }
        let secondWaiter = Task.immediate {
            await second.results(for: request, sources: sources, waiter: UUID(),
                                 execute: { _ in await gate.read("second") })
        }
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.cancel()
        #expect(await firstWaiter.value == nil)
        await gate.waitForCancellation("first")
        var drained = false
        let closing = Task.immediate { await first.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("first", with: ["saved": []])
        await closing.value // The second pass is still held.
        #expect(drained)
        await gate.finish("second", with: ["saved": []])
        #expect(await secondWaiter.value?["saved"] != nil)
        second.cancel()
        await work.waitUntilFinished()
    }
}
