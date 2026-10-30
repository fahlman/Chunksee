import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct SavedQueryWorkTests {
    private func model(work: BackgroundWork, key: String, gate: AsyncReadGate<WorldQueryStore.Results>) -> SearchModel {
        let defaults = TestDefaults.make(), saved = SavedSearches(defaults: TestDefaults.make())
        saved.add("saved")
        return makeSearch(readers: [], work: work, playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults),
            singleplayerUUID: { nil }, firstDimension: nil, savedSearches: saved,
            execute: { _ in await gate.read(key) }, gameNames: { .unavailable })
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureDrainsLateReadsAndRejectsTheirResults() async {
        let work = BackgroundWork(), gate = AsyncReadGate<WorldQueryStore.Results>()
        let model = model(work: work, key: "saved", gate: gate)
        let pending = Task.immediate { await model.waitForSearch() }
        await gate.waitForRequest("saved")
        work.close()
        await gate.waitForCancellation("saved")
        var drained = false
        let closing = Task.immediate { await work.waitUntilFinished(); drained = true }
        #expect(!drained)
        await gate.finish("saved", with: ["saved": []])
        await pending.value
        await closing.value
        #expect(drained && !model.isSearching && model.results(for: "saved").isEmpty)
        model.text = "after"
        await model.waitForSearch()
        #expect(await gate.requested == ["saved"])
        await model.closeTestWorld()
    }

    @Test(.timeLimit(.minutes(1))) func localCancellationReleasesWaitersAndLeavesAnotherConsumerRunning() async {
        let work = BackgroundWork(), gate = AsyncReadGate<WorldQueryStore.Results>()
        let first = model(work: work, key: "first", gate: gate), second = model(work: work, key: "second", gate: gate)
        let firstWaiter = Task.immediate { await first.waitForSearch() }
        let secondWaiter = Task.immediate { await second.waitForSearch() }
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.queryStore.close()
        await firstWaiter.value
        #expect(!first.isSearching && first.results(for: "saved").isEmpty)
        await gate.waitForCancellation("first")
        var drained = false
        let closing = Task.immediate { await first.queryStore.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("first", with: ["saved": []])
        await closing.value // The second world's pass is deliberately still held.
        #expect(drained && second.isSearching)
        await gate.finish("second", with: ["saved": []])
        await secondWaiter.value
        #expect(!second.isSearching)
        await first.closeTestWorld()
        await second.closeTestWorld()
        work.close()
        await work.waitUntilFinished()
    }
}
