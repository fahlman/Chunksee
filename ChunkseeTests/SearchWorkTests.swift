import Foundation
import CoreGraphics
import ChunkseeKit
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores)
struct SearchWorkTests {
    @Observable final class PlayerIdentity {
        var uuid: UUID?
        init(_ uuid: UUID) { self.uuid = uuid }
    }

    private func hit(_ title: String) -> SearchHit {
        SearchHit(id: title, dimension: "minecraft:overworld", position: .zero,
                  y: 64, content: .sign(kind: "minecraft:sign", lines: [title]))
    }

    @Test(.timeLimit(.minutes(1))) func savedQueriesUseTheCurrentSingleplayerIdentityAndRejectRetiredLabels() async {
        let work = BackgroundWork(), defaults = TestDefaults.make(), uuid = UUID()
        let identity = PlayerIdentity(uuid), gate = AsyncReadGate<WorldQueryStore.Results>()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let roster = PlayerRoster([PlayerInfo(uuid: uuid, nbt: .compound([:]))])
        let model = makeSearch(readers: [], work: work, playerRoster: roster,
                                names: PlayerNames(defaults: defaults), singleplayerUUID: { identity.uuid },
                                firstDimension: nil, savedSearches: saved,
                                execute: { await gate.read($0.playerNames[uuid] == .you ? "you" : "other") },
                                gameNames: { .unavailable })
        await model.waitForIndex()
        await gate.waitForRequest("you")
        await gate.finish("you", with: ["saved": .all([hit("You")])])
        await model.waitForSearch()
        #expect(model.results(for: "saved").map(\.id) == ["You"])
        identity.uuid = nil
        #expect(model.results(for: "saved").isEmpty)
        await gate.waitForRequest("other")
        identity.uuid = uuid
        await gate.waitForRequest("you", count: 2)
        await gate.waitForCancellation("other")
        await gate.finish("other", with: ["saved": .all([hit("Retired name")])])
        await gate.finish("you", with: ["saved": .all([hit("Current You")])])
        await model.waitForSearch()
        #expect(model.results(for: "saved").map(\.id) == ["Current You"])
        await model.closeTestWorld()
        work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureDrainsReplacedQueriesAndRejectsLateResults() async {
        let work = BackgroundWork(), defaults = TestDefaults.make()
        let gate = AsyncReadGate<WorldQueryStore.Results>()
        let model = makeSearch(readers: [], work: work, playerRoster: PlayerRoster([]),
                                names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                firstDimension: nil, savedSearches: SavedSearches(defaults: defaults),
                                execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
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
        await gate.finish("current", with: ["current": .all([hit("Late")])])
        await model.waitForSearch()
        #expect(!drained) // The replaced query is still finishing after cancellation.
        await gate.finish("old", with: ["old": .all([hit("Obsolete")])])
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
        let gate = AsyncReadGate<WorldQueryStore.Results>()
        let names = PlayerNames(defaults: defaults), saved = SavedSearches(defaults: defaults)
        let players = PlayerRoster([])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let numbers = ReadNumbers()
        let queries = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable },
            execute: { _ in await gate.read(String(await numbers.next())) })
        let first = SearchModel(queryStore: queries), second = SearchModel(queryStore: queries)
        first.text = "query"
        await gate.waitForRequest("0")
        second.text = "query"
        await gate.waitForRequest("1")
        first.cancel()
        await gate.waitForCancellation("0")
        var drained = false
        let closing = Task.immediate { await first.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("0", with: ["query": .all([hit("Discarded")])])
        await closing.value // The sibling query remains held.
        #expect(drained && first.results.isEmpty && second.isSearching)
        await gate.finish("1", with: ["query": .all([hit("Kept")])])
        await second.waitForSearch()
        #expect(second.results.map(\.id) == ["Kept"])
        second.cancel()
        queries.close()
        await queries.waitForTasks()
        index.cancel()
        await index.waitForTasks()
        work.close()
        await work.waitUntilFinished()
    }
}
