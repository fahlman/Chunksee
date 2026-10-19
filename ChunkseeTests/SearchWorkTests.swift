import Foundation
import CoreGraphics
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct SearchWorkTests {
    private func hit(_ title: String) -> SearchHit {
        SearchHit(id: title, source: .sign, dimension: "minecraft:overworld", position: .zero,
                  y: 64, title: title, detail: title, count: 1)
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureDrainsReplacedQueriesAndRejectsLateResults() async {
        let work = BackgroundWork(), defaults = TestDefaults.make()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let model = SearchModel(readers: [], work: work, playerSnapshot: PlayerSnapshot([]),
                                names: PlayerNames(defaults: defaults), singleplayerUUID: nil,
                                firstDimension: nil, savedSearches: SavedSearches(defaults: defaults),
                                execute: { await gate.read($0.queries[0]) })
        await model.waitForIndex()
        model.text = "old"
        await gate.waitForRequest("old")
        model.text = "current"
        await gate.waitForCancellation("old")
        await gate.waitForRequest("current")
        work.close()
        await gate.waitForCancellation("current")
        var drained = false
        let closing = Task.immediate { await model.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("current", with: ["current": [hit("Late")]])
        await model.waitForSearch()
        #expect(!drained) // The replaced query is still finishing after cancellation.
        await gate.finish("old", with: ["old": [hit("Obsolete")]])
        await closing.value
        #expect(drained && !model.isSearching && model.results.isEmpty)
        model.text = "after"
        await model.waitForSearch()
        #expect(await gate.requested == ["old", "current"])
        model.cancel()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneSearchDrainsOnlyItsQueries() async {
        let work = BackgroundWork(), defaults = TestDefaults.make()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let names = PlayerNames(defaults: defaults), saved = SavedSearches(defaults: defaults)
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil)
        await index.waitForIndex()
        func document(_ key: String) -> SearchModel {
            SearchModel(readers: [], work: work, playerSnapshot: PlayerSnapshot([]), names: names,
                        singleplayerUUID: nil, firstDimension: nil, savedSearches: saved,
                        execute: { _ in await gate.read(key) }, indexStore: index)
        }
        let first = document("first"), second = document("second")
        first.text = "query"
        second.text = "query"
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.cancel()
        await gate.waitForCancellation("first")
        var drained = false
        let closing = Task.immediate { await first.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("first", with: ["query": [hit("Discarded")]])
        await closing.value // The sibling query remains held.
        #expect(drained && first.results.isEmpty && second.isSearching)
        await gate.finish("second", with: ["query": [hit("Kept")]])
        await second.waitForSearch()
        #expect(second.results.map(\.title) == ["Kept"])
        second.cancel()
        index.cancel()
        await index.waitForTasks()
        work.close()
        await work.waitUntilFinished()
    }
}
