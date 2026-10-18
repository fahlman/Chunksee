import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct SharedSavedQueryTests {
    private func hit(_ title: String) -> SearchHit {
        SearchHit(id: title, source: .sign, dimension: "minecraft:overworld", position: .zero,
                  y: 64, title: title, detail: title, count: 1)
    }

    @Test func threeDocumentsReusePendingAndCompletedSavedQueries() async {
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let saved = SavedSearches(defaults: defaults), names = PlayerNames(defaults: defaults)
        saved.add("saved")
        let index = WorldIndexStore(readers: [], firstDimension: nil)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        func document() -> SearchModel {
            SearchModel(readers: [], players: [], names: names, singleplayerUUID: nil,
                        firstDimension: nil, savedSearches: saved,
                        execute: { await gate.read($0.queries[0]) }, indexStore: index)
        }
        let first = document(), second = document(), third = document()
        await gate.waitForRequest("saved")
        await gate.releaseAllAndFuture(with: ["saved": [hit("Shared")]])
        for model in [first, second, third] { await model.waitForSearch() }
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)
        for model in [first, second, third] {
            #expect(model.results(for: "saved").map(\.title) == ["Shared"])
        }

        let later = document()
        await later.waitForSearch()
        #expect(later.results(for: "saved").map(\.title) == ["Shared"])
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)

        first.text = "diamond"
        second.text = "ancient debris"
        first.selectedHitID = "one"
        second.selectedHitID = "two"
        for model in [first, second] { await model.waitForSearch() }
        #expect(first.text == "diamond" && second.text == "ancient debris")
        #expect(first.selectedHitID == "one" && second.selectedHitID == "two")
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)
        for model in [first, second, third, later] { model.cancel(); await model.waitForTasks() }
        index.cancel()
        await index.waitForTasks()
    }
}
