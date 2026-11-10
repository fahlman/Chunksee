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
        SearchHit(id: title, source: .sign, dimension: "minecraft:overworld", position: .zero,
                  y: 64, title: title, detail: title, count: 1)
    }

    @Test(.timeLimit(.minutes(1))) func savedQueriesUseTheCurrentSingleplayerIdentityAndRejectRetiredLabels() async {
        let work = BackgroundWork(), defaults = TestDefaults.make(), uuid = UUID()
        let identity = PlayerIdentity(uuid), gate = AsyncReadGate<[String: [SearchHit]]>()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let roster = PlayerRoster([PlayerInfo(uuid: uuid, nbt: .compound([:]))])
        let model = SearchModel(readers: [], work: work, playerRoster: roster,
                                names: PlayerNames(defaults: defaults), singleplayerUUID: { identity.uuid },
                                firstDimension: nil, savedSearches: saved,
                                execute: { await gate.read($0.playerNames[uuid] == .you ? "you" : "other") },
                                gameNames: { .unavailable })
        await model.waitForIndex()
        await gate.waitForRequest("you")
        await gate.finish("you", with: ["saved": [hit("You")]])
        await model.waitForSearch()
        #expect(model.results(for: "saved").map(\.title) == ["You"])
        identity.uuid = nil
        #expect(model.results(for: "saved").isEmpty)
        await gate.waitForRequest("other")
        identity.uuid = uuid
        await gate.waitForRequest("you", count: 2)
        await gate.waitForCancellation("other")
        await gate.finish("other", with: ["saved": [hit("Retired name")]])
        await gate.finish("you", with: ["saved": [hit("Current You")]])
        await model.waitForSearch()
        #expect(model.results(for: "saved").map(\.title) == ["Current You"])
        model.cancel(); await model.waitForTasks()
        work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func ownerClosureDrainsReplacedQueriesAndRejectsLateResults() async {
        let work = BackgroundWork(), defaults = TestDefaults.make()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let model = SearchModel(readers: [], work: work, playerRoster: PlayerRoster([]),
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
        let players = PlayerRoster([])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        func document(_ key: String) -> SearchModel {
            SearchModel(readers: [], work: work, playerRoster: players, names: names,
                        singleplayerUUID: { nil }, firstDimension: nil, savedSearches: saved,
                        execute: { _ in await gate.read(key) }, indexStore: index, gameNames: { .unavailable })
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
