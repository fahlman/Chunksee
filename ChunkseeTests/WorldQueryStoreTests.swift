import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldQueryStoreTests {
    @Test func typingACompletedSavedQueryShowsItsResultsImmediately() async {
        let defaults = TestDefaults.make(), work = BackgroundWork()
        let saved = SavedSearches(defaults: defaults), gate = AsyncReadGate<WorldQueryStore.Results>()
        saved.add("saved")
        func hit(_ title: String) -> SearchHit {
            SearchHit(id: title, source: .sign, dimension: nil, position: .zero,
                      y: 64, title: title, detail: title, count: 1)
        }
        let model = makeSearch(readers: [], work: work, playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults),
            singleplayerUUID: { nil }, firstDimension: nil, savedSearches: saved,
            execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        await gate.waitForRequest("saved")
        await gate.finish("saved", with: ["saved": [hit("Saved")]])
        await model.waitForSearch()
        model.text = "first"
        await gate.waitForRequest("first")
        await gate.finish("first", with: ["first": [hit("First")]])
        await model.waitForSearch()
        model.text = "saved"
        #expect(model.results.map(\.title) == ["Saved"] && !model.isSearching)
        await model.waitForSearch()
        #expect(await gate.requested == ["saved", "first"])
        await model.closeTestWorld()
    }

    @Test func queriesWaitForTheMatchingPlayerAndCarriedPetProjection() async throws {
        let fixtures = ShoulderPetTests(), url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        func player(_ x: Double) -> PlayerInfo {
            PlayerInfo(uuid: fixtures.carrier, nbt: fixtures.playerData(pets: [fixtures.parrot(fixtures.bird)],
                dimension: .string(fixtures.overworld), position: [x, 64, 0]))
        }
        let work = BackgroundWork(), players = PlayerRoster([player(1)])
        let projection = AsyncReadGate<Void>(), reads = AsyncReadGate<Void>()
        let index = WorldIndexStore(readers: [reader], work: work, firstDimension: nil, playerRoster: players,
            projectCreatures: { base, pets in
                if pets[0].location!.x != 1 { await projection.read(String(pets[0].location!.x)) }
                return await base.including(pets)
            }, readDimension: { _, _, _ in DimensionContent() })
        await index.waitForIndex()
        let defaults = TestDefaults.make(), saved = SavedSearches(defaults: defaults)
        saved.add("Gray")
        await reads.releaseAllAndFuture(with: ())
        let store = WorldQueryStore(index: index, work: work, names: PlayerNames(defaults: defaults), savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { request in
                let carrier = request.players.first?.position?.x ?? -1
                let pet = request.index.creatures.first?.value.position.x ?? -1
                await reads.read("\(carrier):\(pet)")
                return await WorldSearch.execute(request)
            })
        let window = SearchModel(queryStore: store)
        await window.waitForSearch()
        #expect(window.results(for: "Gray").compactMap { $0.position?.x } == [1])
        players.publish([player(2)])
        await projection.waitForRequest("2.0")
        #expect(window.isSearching && window.results(for: "Gray").compactMap { $0.position?.x } == [1])
        players.publish([player(3)])
        await projection.waitForRequest("3.0")
        await projection.waitForCancellation("2.0")
        await projection.finish("3.0", with: ())
        await window.waitForSearch()
        #expect(window.results(for: "Gray").compactMap { $0.position?.x } == [3])
        await projection.finish("2.0", with: ())
        await index.waitForTasks()
        await window.waitForSearch()
        #expect(window.results(for: "Gray").compactMap { $0.position?.x } == [3])
        #expect(await reads.requested == ["1.0:1.0", "3.0:3.0"])
        window.cancel(); store.close(); index.cancel()
        await work.waitUntilFinished()
        await reader.close()
    }

    @Test func savedResultsRefreshWithoutAWindowAndLaterWindowsUseThePublication() async {
        let work = BackgroundWork(), defaults = TestDefaults.make(), uuid = UUID()
        let saved = SavedSearches(defaults: defaults), gate = AsyncReadGate<WorldQueryStore.Results>()
        saved.add("saved")
        func player(_ level: Int32) -> PlayerInfo {
            PlayerInfo(uuid: uuid, nbt: .compound(["XpLevel": .int(level)]))
        }
        func hit(_ title: String) -> SearchHit {
            SearchHit(id: title, source: .sign, dimension: nil, position: .zero,
                      y: 64, title: title, detail: title, count: 1)
        }
        let players = PlayerRoster([player(1)])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let store = WorldQueryStore(index: index, work: work, names: PlayerNames(defaults: defaults), savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable },
            execute: { await gate.read(String($0.players[0].experienceLevel!)) })
        await gate.waitForRequest("1")
        await gate.finish("1", with: ["saved": [hit("First")]])
        await store.waitForTasks()
        #expect(store.results(for: "saved").map(\.title) == ["First"])
        players.publish([player(2)])
        await gate.waitForRequest("2")
        #expect(store.results(for: "saved").map(\.title) == ["First"])
        await gate.finish("2", with: ["saved": [hit("Second")]])
        await store.waitForTasks()
        let window = SearchModel(queryStore: store)
        await window.waitForSearch()
        #expect(window.results(for: "saved").map(\.title) == ["Second"])
        #expect(await gate.requested == ["1", "2"])
        window.cancel()
        store.close(); index.cancel()
        await work.waitUntilFinished()
    }

    @Test func parentScopeDrainsRetiredChildrenWithoutClosingASiblingOwner() async {
        let work = BackgroundWork(), parent = work.makeScope(), unrelated = work.makeScope()
        var child: BackgroundWork.Scope? = parent.makeScope()
        let sibling = parent.makeScope(), descendant = sibling.makeScope(), gate = AsyncReadGate<Void>()
        child?.start(priority: .utility) { await gate.read("retired") }
        descendant.start(priority: .utility) { await gate.read("descendant") }
        unrelated.start(priority: .utility) { await gate.read("unrelated") }
        for key in ["retired", "descendant", "unrelated"] { await gate.waitForRequest(key) }
        child?.close()
        child = nil
        await gate.waitForCancellation("retired")
        #expect(!sibling.isClosed && !descendant.isClosed && !unrelated.isClosed)
        parent.close()
        await gate.waitForCancellation("descendant")
        #expect(descendant.isClosed && !unrelated.isClosed)
        #expect(descendant.start(priority: .utility) { await gate.read("refused") } == nil)
        var drained = false
        let closing = Task.immediate { await parent.waitUntilFinished(); drained = true }
        #expect(!drained)
        await gate.finish("descendant", with: ())
        await descendant.waitUntilFinished()
        #expect(!drained && parent.unfinishedCount == 1)
        await gate.finish("retired", with: ())
        await closing.value
        #expect(drained && unrelated.unfinishedCount == 1)
        work.close()
        await gate.waitForCancellation("unrelated")
        await gate.finish("unrelated", with: ())
        await work.waitUntilFinished()
        #expect(Set(await gate.requested) == ["retired", "descendant", "unrelated"])
    }
}
