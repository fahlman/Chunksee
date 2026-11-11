import ChunkseeIndex
import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct SharedSavedQueryTests {
    private func hit(_ title: String) -> SearchHit {
        SearchHit(id: title, dimension: "minecraft:overworld", position: .zero,
                  y: 64, content: .sign(kind: "minecraft:sign", lines: [title]))
    }

    @Test func threeDocumentsReusePendingAndCompletedSavedQueries() async {
        let work = BackgroundWork()
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults), names = PlayerNames(defaults: defaults)
        saved.add("saved")
        let players = PlayerRoster([])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let queries = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { await gate.read($0.queries[0]) })
        func document() -> SearchModel { SearchModel(queryStore: queries) }
        let first = document(), second = document(), third = document()
        await gate.waitForRequest("saved")
        await gate.releaseAllAndFuture(with: ["saved": [hit("Shared")]])
        for model in [first, second, third] { await model.waitForSearch() }
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)
        for model in [first, second, third] {
            #expect(model.results(for: "saved").map(\.id) == ["Shared"])
        }

        let later = document()
        await later.waitForSearch()
        #expect(later.results(for: "saved").map(\.id) == ["Shared"])
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)

        first.text = "diamond"
        second.text = "ancient debris"
        for model in [first, second] { await model.waitForSearch() }
        #expect(first.text == "diamond" && second.text == "ancient debris")
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)
        for model in [first, second, third, later] { model.cancel(); await model.waitForTasks() }
        queries.close()
        index.cancel()
        await queries.waitForTasks()
        await index.waitForTasks()
    }

    @Test func closingTheRequesterStopsItsWaitWithoutCancellingTheSharedPass() async {
        let work = BackgroundWork()
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults), names = PlayerNames(defaults: defaults)
        saved.add("saved")
        let players = PlayerRoster([])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let queries = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { await gate.read($0.queries[0]) })
        func document() -> SearchModel { SearchModel(queryStore: queries) }
        let first = document()
        await gate.waitForRequest("saved")
        let second = document()
        first.cancel()
        // This must finish while the shared pass remains blocked at the gate.
        await first.waitForTasks()
        #expect(first.results(for: "saved").isEmpty && !first.isSearching)
        await gate.finish("saved", with: ["saved": [hit("Shared")]])
        await second.waitForSearch()
        #expect(second.results(for: "saved").map(\.id) == ["Shared"])
        #expect(await gate.requested == ["saved"])
        second.cancel()
        await second.waitForTasks()
        queries.close()
        index.cancel()
        await queries.waitForTasks()
        await index.waitForTasks()
    }

    @Test func removingTheLastUseCancelsAndWorldClosureDrainsARetiredPass() async throws {
        let work = BackgroundWork()
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let id = try #require(saved.all.first?.id)
        let players = PlayerRoster([])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let queries = WorldQueryStore(index: index, work: work, names: PlayerNames(defaults: defaults), savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { await gate.read($0.queries[0]) })
        let model = SearchModel(queryStore: queries)
        await gate.waitForRequest("saved")
        saved.remove(id)
        await model.waitForSearch()
        await gate.waitForCancellation("saved")
        #expect(model.results(for: "saved").isEmpty)
        model.cancel()
        await model.waitForTasks()
        queries.close()
        index.cancel()
        var drained = false
        let closing = Task.immediate { await queries.waitForTasks(); await index.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("saved", with: ["saved": [hit("Obsolete")]])
        await closing.value
        #expect(drained && model.results(for: "saved").isEmpty)
    }

    @Test func removingASavedQueryKeepsAnActiveTypedWaiterAndDoesNotCacheItAfterwards() async throws {
        let work = BackgroundWork()
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let id = try #require(saved.all.first?.id)
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let model = makeSearch(readers: [], work: work, playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                firstDimension: nil, savedSearches: saved,
                                execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        await gate.waitForRequest("saved")
        model.text = "saved"
        saved.remove(id)
        let current = Task.immediate { await model.waitForSearch() }
        await gate.finish("saved", with: ["saved": [hit("Still Wanted")]])
        await current.value
        #expect(model.results.map(\.id) == ["Still Wanted"])
        model.text = ""
        await model.waitForSearch()
        saved.add("saved")
        let again = Task.immediate { await model.waitForSearch() }
        await gate.waitForRequest("saved")
        await gate.releaseAllAndFuture(with: ["saved": [hit("New Pass")]])
        await again.value
        #expect(await gate.requested == ["saved", "saved"])
        #expect(model.results(for: "saved").map(\.id) == ["New Pass"])
        await model.closeTestWorld()
    }

    @Test func sameCountPlayerUpdatesAndNewlyOpenedDocumentsShareOnlyMatchingSources() async {
        let work = BackgroundWork()
        let defaults = TestDefaults.make(), uuid = UUID()
        let saved = SavedSearches(defaults: defaults), names = PlayerNames(defaults: defaults)
        saved.add("saved")
        func player(_ revision: Int32) -> PlayerInfo {
            PlayerInfo(uuid: uuid, nbt: .compound(["XpLevel": .int(revision)]))
        }
        let players = PlayerRoster([player(1)])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let queries = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { await gate.read(String($0.players[0].experienceLevel!)) })
        func document() -> SearchModel { SearchModel(queryStore: queries) }
        let first = document(), second = document()
        await gate.waitForRequest("1")
        players.publish([player(2)])
        await gate.waitForRequest("2")
        await gate.finish("2", with: ["saved": [hit("New")]])
        for model in [first, second] { await model.waitForSearch() }
        let later = document()
        await later.waitForSearch()
        await first.waitForSearch()
        #expect(await gate.requested.filter { $0 == "1" }.count == 1)
        #expect(await gate.requested.filter { $0 == "2" }.count == 1)
        await gate.finish("1", with: ["saved": [hit("Obsolete")]])
        for model in [first, second, later] {
            await model.waitForTasks()
            #expect(model.results(for: "saved").map(\.id) == ["New"])
            model.cancel()
        }
        queries.close()
        index.cancel()
        await queries.waitForTasks()
        await index.waitForTasks()
    }

    @Test(.timeLimit(.minutes(1))) func closedSearchDoesNotRestartWhenTheSharedRosterPublishes() async {
        let work = BackgroundWork()
        let defaults = TestDefaults.make(), uuid = UUID()
        let names = PlayerNames(defaults: defaults), saved = SavedSearches(defaults: defaults)
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        func player(_ revision: Int32) -> PlayerInfo {
            PlayerInfo(uuid: uuid, nbt: .compound(["XpLevel": .int(revision)]))
        }
        let players = PlayerRoster([player(1)])
        func document(_ label: String) -> SearchModel {
            makeSearch(readers: [], work: work, playerRoster: players, names: names, singleplayerUUID: { nil },
                        firstDimension: nil, savedSearches: saved,
                        execute: { await gate.read("\(label)-\($0.players[0].experienceLevel!)") }, gameNames: { .unavailable })
        }
        let first = document("first"), second = document("second")
        await first.waitForIndex()
        await second.waitForIndex()
        first.text = "query"
        second.text = "query"
        await gate.waitForRequest("first-1")
        await gate.waitForRequest("second-1")
        first.cancel()
        await gate.waitForCancellation("first-1")
        players.publish([player(2)])
        await gate.waitForRequest("second-2")
        await gate.waitForCancellation("second-1")
        await gate.finish("first-1", with: ["query": [hit("Obsolete")]])
        await gate.finish("second-1", with: ["query": [hit("Obsolete")]])
        await gate.finish("second-2", with: ["query": [hit("Current")]])
        await first.waitForTasks()
        await second.waitForSearch()
        #expect(first.results.isEmpty)
        #expect(second.results.map(\.id) == ["Current"])
        #expect(Set(await gate.requested) == ["first-1", "second-1", "second-2"])
        await first.closeTestWorld()
        await second.closeTestWorld()
    }

    @Test func sharedNamesInvalidateOnceAndKeepPreviousSnapshotsWhileSearching() async {
        let work = BackgroundWork()
        let defaults = TestDefaults.make(), uuid = UUID()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in (Data(#"{"name":"Known"}"#.utf8), 200) }))
        names.looksUpOnline = true
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let player = PlayerInfo(uuid: uuid, nbt: .compound([:]))
        let unknown = PlayerPresentation.name(of: player, singleplayerUUID: nil)
        let players = PlayerRoster([player])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let queries = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, execute: { await gate.read($0.playerNames[uuid]!.text) })
        func document() -> SearchModel { SearchModel(queryStore: queries) }
        let first = document(), second = document()
        await gate.waitForRequest(unknown)
        await gate.finish(unknown, with: ["saved": [hit("Previous")]])
        for model in [first, second] { await model.waitForSearch() }
        await names.lookUp([uuid])
        await gate.waitForRequest("Known")
        #expect(first.results(for: "saved").map(\.id) == ["Previous"])
        #expect(second.results(for: "saved").map(\.id) == ["Previous"])
        await gate.finish("Known", with: ["saved": [hit("Known")]])
        for model in [first, second] {
            await model.waitForSearch()
            #expect(model.results(for: "saved").map(\.id) == ["Known"])
            model.cancel()
            await model.waitForTasks()
        }
        #expect(await gate.requested == [unknown, "Known"])
        queries.close()
        index.cancel()
        await queries.waitForTasks()
        await index.waitForTasks()
    }

    @Test func worldPublishesOnePlayerSnapshotForOpenAndLaterDocuments() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        for folder in ["DIM-1/region", "DIM1/region"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let original = try await WorldSnapshot.read(url)
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "Dimension": .string("minecraft:the_nether"), "Pos": .list([.double(2), .double(63), .double(3)]),
            "Inventory": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(4)])]),
        ]))
        let snapshot = WorldSnapshot(access: original.access, world: original.world, dimensions: original.dimensions,
                                     dimensionDocuments: original.dimensionDocuments, players: [player], details: original.details)
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("diamond")
        let resources = try await WorldResources(snapshot: snapshot, names: PlayerNames(defaults: defaults),
                                       savedSearches: saved, defaults: defaults, cacheRoot: nil)
        var sessions = ["minecraft:overworld", "minecraft:the_nether"].map { WorldSession(resources: resources, dimensionID: $0) }
        let originalPlayers = resources.playerSnapshot
        #expect(resources.dimensions.count == 3 && sessions.count == 2)
        for session in sessions {
            #expect(session.search.queryStore === resources.queryStore)
            #expect(session.search.playerSnapshot === originalPlayers)
            await session.search.waitForIndex()
            await session.search.waitForSearch()
            let found = session.search.results(for: "diamond")
            #expect(found.count == 1 && found.first?.source == .inventory(player.uuid))
            #expect(found.first?.count == 4 && found.first?.dimension == "minecraft:the_nether")
        }

        let overworld = sessions[0], nether = sessions[1]
        let sharedHit = try #require(nether.search.results(for: "diamond").first)
        nether.selection.choose(.hit(query: "diamond", id: sharedHit.id))
        overworld.selection.choose(.worldInfo)
        #expect(nether.selection.selectedHitID == sharedHit.id && overworld.selection.selectedHitID == nil)
        #expect(nether.selection.sidebarSelection == .hit(query: "diamond", id: sharedHit.id))
        #expect(overworld.selection.sidebarSelection == .worldInfo)

        // Same UUID, save date and roster size, but a different inventory. All documents must
        // switch to one new publication and expose real updated results, including a later opener.
        let updated = PlayerInfo(uuid: player.uuid, nbt: .compound([
            "Dimension": .string("minecraft:the_nether"), "Pos": .list([.double(2), .double(63), .double(3)]),
            "Inventory": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(7)])]),
        ]), lastSaved: player.lastSaved)
        resources.refreshDelay = .zero
        resources.readPlayers = { _, _ in [updated] }
        resources.worldChanged([resources.world.playerDataDirectory.appendingPathComponent("\(player.uuid).dat")])
        await resources.waitForRefresh()
        #expect(resources.playerSnapshot !== originalPlayers)
        let later = WorldSession(resources: resources, dimensionID: resources.dimensions[2].id)
        sessions.append(later)
        for session in sessions {
            #expect(session.search.playerSnapshot === resources.playerSnapshot)
            await session.search.waitForSearch()
            let found = session.search.results(for: "diamond")
            #expect(found.count == 1 && found.first?.count == 7 && found.first?.source == .inventory(player.uuid))
        }
        resources.close()
        await resources.waitUntilClosed()
        for session in sessions { #expect(session.isClosed) }
    }

    @Test func sharedKeysIncludeIndexVersionAndPlayerPublication() async {
        let work = BackgroundWork(), defaults = TestDefaults.make(), numbers = ReadNumbers()
        let uuid = UUID(), other = UUID(), date = Date(timeIntervalSince1970: 1)
        let playerData = NBT.compound([:])
        let players = PlayerRoster([PlayerInfo(uuid: uuid, nbt: playerData)])
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let gate = AsyncReadGate<WorldQueryStore.Results>()
        await gate.releaseAllAndFuture(with: ["saved": [hit("Result")]])
        let index = WorldIndexStore(readers: [], work: work, firstDimension: nil, playerRoster: players)
        await index.waitForIndex()
        let queries = WorldQueryStore(index: index, work: work, names: PlayerNames(defaults: defaults), savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable },
            execute: { _ in await gate.read(String(await numbers.next())) })
        let first = SearchModel(queryStore: queries), second = SearchModel(queryStore: queries)
        for step in 0..<4 {
            if step == 1 { index.replace(readers: [], firstDimension: nil) }
            if step == 2 { players.publish([PlayerInfo(uuid: other, nbt: playerData)]) }
            if step == 3 { players.publish([PlayerInfo(uuid: other, nbt: playerData, lastSaved: date)]) }
            for model in [first, second] {
                await model.waitForSearch()
                #expect(model.results(for: "saved").map(\.id) == ["Result"])
            }
        }
        #expect(await gate.requested == ["0", "1", "2", "3"])
        first.cancel(); second.cancel()
        queries.close(); index.cancel()
        await work.waitUntilFinished()
    }

    @Test func closingTheWorldReleasesWaitersButWaitsForTheUnderlyingPass() async {
        let work = BackgroundWork(), defaults = TestDefaults.make()
        let gate = AsyncReadGate<WorldQueryStore.Results>()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let model = makeSearch(readers: [], work: work, playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults),
            singleplayerUUID: { nil }, firstDimension: nil, savedSearches: saved,
            execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        let pending = Task.immediate { await model.waitForSearch() }
        await gate.waitForRequest("saved")
        model.queryStore.close()
        await pending.value
        #expect(model.results(for: "saved").isEmpty)
        await gate.waitForCancellation("saved")
        var drained = false
        let closing = Task.immediate { await model.queryStore.waitForTasks(); drained = true }
        #expect(!drained)
        await gate.finish("saved", with: ["saved": [hit("Late")]])
        await closing.value
        #expect(drained)
        let after = SearchModel(queryStore: model.queryStore)
        after.text = "saved"
        await after.waitForSearch()
        #expect(after.results.isEmpty && !after.isSearching)
        #expect(await gate.requested == ["saved"])
        await model.closeTestWorld()
    }
}
