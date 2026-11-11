import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct NameSourceLifetimeTests {
    func defaults() -> UserDefaults { TestDefaults.make() }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelingOneNameSourceLeavesTheOtherRunning(cancelLocal: Bool) async throws {
        let localGate = AsyncReadGate<[UUID: String]>(), onlineGate = AsyncReadGate<(Data, Int)>()
        let folder = try TestWorld.make(chunks: []), localID = UUID(), onlineID = UUID()
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = PlayerNames(defaults: defaults(),
                                mojang: MojangProfiles(fetch: { _ in await onlineGate.read("online") }),
                                readCaches: { _ in await localGate.read("local") })
        names.looksUpOnline = true
        let choosing = Task { await names.chooseMinecraftFolder(folder) }
        let lookup = Task { await names.lookUp([onlineID]) }
        await localGate.waitForRequest("local")
        await onlineGate.waitForRequest("online")
        if cancelLocal {
            names.forgetMinecraftFolder()
            await localGate.waitForCancellation("local")
        } else {
            names.looksUpOnline = false
            await onlineGate.waitForCancellation("online")
        }
        await localGate.finish("local", with: [localID: "Local Name"])
        await onlineGate.finish("online", with: (Data(#"{"name":"OnlineName"}"#.utf8), 200))
        await choosing.value
        await lookup.value
        #expect(names.name(for: localID) == (cancelLocal ? nil : "Local Name"))
        #expect(names.name(for: onlineID) == (cancelLocal ? "OnlineName" : nil))
        #expect(await localGate.requested == ["local"])
        #expect(await onlineGate.requested == ["online"])
        names.forgetMinecraftFolder()
        names.looksUpOnline = false
    }

    @Test func turningLookupOffCancelsTheRequestAndStopsTheBatch() async {
        let gate = AsyncReadGate<(Data, Int)>()
        let first = UUID(), second = UUID()
        let key = MojangProfiles.profileURL(for: first).lastPathComponent
        let names = PlayerNames(defaults: defaults(), mojang: MojangProfiles(fetch: { await gate.read($0.lastPathComponent) }))
        names.looksUpOnline = true
        let lookup = Task { await names.lookUp([first, second]) }
        await gate.waitForRequest(key)
        names.looksUpOnline = false
        await gate.waitForCancellation(key)
        await gate.finish(key, with: (Data(#"{"name":"Late"}"#.utf8), 200))
        await lookup.value
        #expect(names.online.isEmpty)
        #expect(await gate.requested == [key])
    }

    @Test func clearingNamesRejectsAnAnswerAlreadyInFlight() async {
        let gate = AsyncReadGate<(Data, Int)>()
        let uuid = UUID(), store = defaults()
        let key = MojangProfiles.profileURL(for: uuid).lastPathComponent
        let names = PlayerNames(defaults: store, mojang: MojangProfiles(fetch: { await gate.read($0.lastPathComponent) }))
        names.looksUpOnline = true
        let lookup = Task { await names.lookUp([uuid]) }
        await gate.waitForRequest(key)
        names.clearOnlineNames()
        await gate.waitForCancellation(key)
        await gate.finish(key, with: (Data(#"{"name":"Late"}"#.utf8), 200))
        await lookup.value
        #expect(names.online.isEmpty)
        #expect(store.dictionary(forKey: "onlinePlayerNames") == nil)
    }

    @Test func forgettingTheLocalFolderRejectsItsPendingNames() async throws {
        let gate = AsyncReadGate<[UUID: String]>()
        let folder = try TestWorld.make(chunks: []), uuid = UUID()
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = PlayerNames(defaults: defaults(), readCaches: { await gate.read($0.path) })
        let choosing = Task { await names.chooseMinecraftFolder(folder) }
        await gate.waitForRequest(folder.path)
        names.forgetMinecraftFolder()
        await gate.waitForCancellation(folder.path)
        await gate.finish(folder.path, with: [uuid: "Old Folder"])
        await choosing.value
        #expect(names.minecraftFolder == nil && names.local.isEmpty)
    }

    @Test func aNewLocalFolderWinsEvenWhenTheOldOneFinishesLast() async throws {
        let gate = AsyncReadGate<[UUID: String]>()
        let old = try TestWorld.make(chunks: []), new = try TestWorld.make(chunks: []), uuid = UUID()
        defer { for url in [old, new] { try? FileManager.default.removeItem(at: url) } }
        let names = PlayerNames(defaults: defaults(), readCaches: { await gate.read($0.path) })
        let first = Task { await names.chooseMinecraftFolder(old) }
        await gate.waitForRequest(old.path)
        let second = Task { await names.chooseMinecraftFolder(new) }
        await gate.waitForRequest(new.path)
        await gate.finish(new.path, with: [uuid: "New Folder"])
        await second.value
        await gate.finish(old.path, with: [uuid: "Old Folder"])
        await first.value
        #expect(names.minecraftFolder == new && names.name(for: uuid) == "New Folder")
    }
}

@Suite(.isolatedStores) struct SharedNameReadTests {
    @Test func requestTracksThePlayerRosterWithoutDependingOnItsPositionsOrOrder() async {
        let first = UUID(), second = UUID()
        func player(_ uuid: UUID, x: Double?) -> PlayerInfo {
            var fields: [String: NBT] = ["DataVersion": .int(5023), "Dimension": .string("minecraft:overworld")]
            if let x { fields["Pos"] = .list([.double(x), .double(64), .double(0)]) }
            return PlayerInfo(uuid: uuid, nbt: .compound(fields))
        }
        let gate = AsyncReadGate<(Data, Int)>()
        let names = PlayerNames(defaults: TestDefaults.make(),
                                mojang: MojangProfiles(fetch: { await gate.read($0.lastPathComponent) }))
        names.looksUpOnline = true
        let request = names.request(for: [player(first, x: 0), player(second, x: nil)])
        #expect(request.players == [first, second])
        #expect(request == names.request(for: [player(second, x: nil), player(first, x: 100)]))
        #expect(request != names.request(for: [player(first, x: 0)]))
        await gate.releaseAllAndFuture(with: (Data(#"{"name":"Known"}"#.utf8), 200))
        await names.load(request)
        #expect(names.name(for: first) == "Known" && names.name(for: second) == "Known")
        #expect(Set(await gate.requested) == Set([first, second].map { MojangProfiles.profileURL(for: $0).lastPathComponent }))
        names.looksUpOnline = false
        #expect(request != names.request(for: [player(first, x: 0), player(second, x: nil)]))
        names.clearOnlineNames()
        await names.load(request) // a stale permission request cannot restart a source
        #expect(names.online.isEmpty)
    }

    @Test func overlappingLocalRequestsShareTheReadAndOneCanceledDocumentCannotLoseIt() async throws {
        let gate = AsyncReadGate<[UUID: String]>()
        let folder = try TestWorld.make(chunks: []), uuid = UUID()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults, readCaches: { await gate.read($0.path) })
        let first = Task.immediate { await names.chooseMinecraftFolder(folder) }
        await gate.waitForRequest(folder.path)
        // Run this MainActor caller through its first suspension before releasing the source.
        let second = Task.immediate { await names.reloadLocal() }
        second.cancel()
        await gate.releaseAllAndFuture(with: [uuid: "Shared Local Name"])
        await first.value
        await second.value
        #expect(names.name(for: uuid) == "Shared Local Name")
        #expect(await gate.requested == [folder.path])
        await names.reloadLocal() // a later, nonoverlapping reload still rereads the chosen source
        #expect(await gate.requested == [folder.path, folder.path])
        names.forgetMinecraftFolder()
    }

    @Test func closingTheRequestingDocumentDoesNotDiscardTheGloballyDeduplicatedProfile() async {
        let uuid = UUID(), gate = AsyncReadGate<(Data, Int)>()
        let key = MojangProfiles.profileURL(for: uuid).lastPathComponent
        let names = PlayerNames(defaults: TestDefaults.make(),
                                mojang: MojangProfiles(fetch: { await gate.read($0.lastPathComponent) }))
        names.looksUpOnline = true
        let first = Task.immediate { await names.lookUp([uuid]) }
        await gate.waitForRequest(key)
        let second = Task.immediate { await names.lookUp([uuid]) }
        await second.value // the second document has already joined the shared attempt policy
        first.cancel()
        await gate.finish(key, with: (Data(#"{"name":"Shared Online Name"}"#.utf8), 200))
        await first.value
        #expect(names.name(for: uuid) == "Shared Online Name")
        #expect(await gate.requested == [key])
        names.looksUpOnline = false
    }
}

@Suite(.isolatedStores) struct SearchRequestLifetimeTests {
    func hit(_ name: String) -> SearchHit {
        SearchHit(id: name, dimension: "minecraft:overworld", position: .zero, y: 64,
                  content: .sign(kind: "minecraft:sign", lines: [name]))
    }

    @Test func editingKeepsTheDisplayedResultsAndReusesCompletedSavedSearches() async {
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                 firstDimension: nil, savedSearches: saved, execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        await gate.waitForRequest("saved")
        await gate.finish("saved", with: ["saved": [hit("Saved")]])
        await search.waitForSearch()
        search.text = "first"
        await gate.waitForRequest("first")
        await gate.finish("first", with: ["first": [hit("First")]])
        await search.waitForSearch()

        search.text = "second"
        await gate.waitForRequest("second")
        #expect(search.isSearching)
        #expect(search.results.map(\.id) == ["First"])
        #expect(search.results(for: "second").map(\.id) == ["First"])
        #expect(search.results(for: "saved").map(\.id) == ["Saved"])
        await gate.finish("second", with: ["second": [hit("Second")]])
        await search.waitForSearch()
        #expect(search.results.map(\.id) == ["Second"])
        #expect(search.results(for: "first").isEmpty)
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)

        search.text = ""
        #expect(search.results.isEmpty && search.results(for: "").isEmpty)
        #expect(search.results(for: "saved").map(\.id) == ["Saved"])
        await search.closeTestWorld()
    }

    @Test func editingDoesNotCancelOrRepeatAPendingSavedSearch() async {
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                 firstDimension: nil, savedSearches: saved, execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        await gate.waitForRequest("saved")
        search.text = "first"
        await gate.waitForRequest("first")
        search.text = "second"
        await gate.waitForRequest("second")
        await gate.finish("saved", with: ["saved": [hit("Saved")]])
        await gate.finish("second", with: ["second": [hit("Second")]])
        await search.waitForSearch()
        await gate.finish("first", with: ["first": [hit("Obsolete")]])
        await search.waitForTasks()
        #expect(search.results.map(\.id) == ["Second"])
        #expect(search.results(for: "saved").map(\.id) == ["Saved"])
        #expect(await gate.requested.filter { $0 == "saved" }.count == 1)
        await search.closeTestWorld()
    }

    @Test func sourceChangesKeepSnapshotsUntilTheirReplacementsArrive() async {
        let defaults = TestDefaults.make()
        let saved = SavedSearches(defaults: defaults)
        saved.add("saved")
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let players = PlayerRoster([])
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: players, names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                 firstDimension: nil, savedSearches: saved,
                                 execute: { await gate.read("\($0.queries[0])-\($0.players.count)") }, gameNames: { .unavailable })
        search.text = "query"
        for query in ["saved", "query"] {
            await gate.waitForRequest("\(query)-0")
            await gate.finish("\(query)-0", with: [query: [hit("Previous \(query)")]])
        }
        await search.waitForSearch()
        players.publish([PlayerInfo(uuid: UUID(), nbt: .compound([:]))])
        for query in ["saved", "query"] { await gate.waitForRequest("\(query)-1") }
        #expect(search.results.map(\.id) == ["Previous query"])
        #expect(search.results(for: "saved").map(\.id) == ["Previous saved"])
        for query in ["saved", "query"] {
            await gate.finish("\(query)-1", with: [query: [hit("Updated \(query)")]])
        }
        await search.waitForSearch()
        #expect(search.results.map(\.id) == ["Updated query"])
        #expect(search.results(for: "saved").map(\.id) == ["Updated saved"])
        await search.closeTestWorld()
    }

    @Test func anOldQueryCannotPublishOverTheNewQuery() async {
        let defaults = TestDefaults.make()
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: PlayerRoster([]), names: PlayerNames(defaults: defaults), singleplayerUUID: { nil },
                                 firstDimension: nil, savedSearches: SavedSearches(defaults: defaults),
                                 execute: { await gate.read($0.queries[0]) }, gameNames: { .unavailable })
        search.text = "old"
        await gate.waitForRequest("old")
        search.text = "new"
        await gate.waitForRequest("new")
        await gate.finish("new", with: ["new": [hit("Current")]])
        await search.waitForSearch()
        await gate.finish("old", with: ["old": [hit("Obsolete")]])
        await search.waitForTasks()
        #expect(search.results.map(\.id) == ["Current"])
        #expect(search.results(for: "old").isEmpty)
        await search.closeTestWorld()
    }

    @Test func sharedNameChangesReplaceTheQuerySnapshot() async {
        let defaults = TestDefaults.make(), uuid = UUID()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in (Data(#"{"name":"Known"}"#.utf8), 200) }))
        names.looksUpOnline = true
        let player = PlayerInfo(uuid: uuid, nbt: .compound([:]))
        let unknown = GameNames.unavailable.player(.unnamed(uuid))
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = makeSearch(readers: [], work: BackgroundWork(), playerRoster: PlayerRoster([player]), names: names, singleplayerUUID: { nil }, firstDimension: nil,
                                 savedSearches: SavedSearches(defaults: defaults),
                                 execute: { await gate.read($0.gameNames.player($0.playerNames[uuid]!)) }, gameNames: { .unavailable })
        search.text = "diamond"
        await gate.waitForRequest(unknown)
        await names.lookUp([uuid])
        await gate.waitForRequest("Known")
        await gate.finish("Known", with: ["diamond": [hit("Known")]])
        await search.waitForSearch()
        await gate.finish(unknown, with: ["diamond": [hit("Unknown")]])
        await search.waitForTasks()
        #expect(search.results.map(\.id) == ["Known"])
        await search.closeTestWorld()
    }
}
