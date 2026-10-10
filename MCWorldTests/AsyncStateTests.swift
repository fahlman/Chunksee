import CoreGraphics
import Foundation
import MCWorldKit
import Testing
@testable import MCWorld

@Suite struct NameSourceLifetimeTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "MCWorldTests-\(UUID())")! }

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

@Suite struct InspectorReadLifetimeTests {
    @Test func thePreviousPlayerCannotReplaceTheCurrentPlayersRecords() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let world = try World(contentsOf: url), first = UUID(), second = UUID()
        let gate = AsyncReadGate<PlayerRecords>()
        let model = PlayerRecordsModel(world: world, read: { uuid, _ in await gate.read(uuid.uuidString) })
        let oldRead = Task { await model.load(first, name: nil) }
        await gate.waitForRequest(first.uuidString)
        let currentRead = Task { await model.load(second, name: nil) }
        await gate.waitForRequest(second.uuidString)
        await gate.finish(second.uuidString, with: .init(statistics: PlayerStatistics(values: ["minecraft:custom": ["minecraft:deaths": 2]])))
        await currentRead.value
        await gate.finish(first.uuidString, with: .init(statistics: PlayerStatistics(values: ["minecraft:custom": ["minecraft:deaths": 1]])))
        await oldRead.value
        #expect(model.uuid == second && model.records?.statistics?.value("minecraft:deaths") == 2)
        model.close()
        await model.load(first, name: nil)
        #expect(model.records == nil && model.uuid == nil)
    }
}

@Suite struct SearchRequestLifetimeTests {
    func hit(_ name: String) -> SearchHit {
        SearchHit(id: name, source: .sign, dimension: "minecraft:overworld", position: .zero, y: 64,
                  title: name, detail: name, count: 1)
    }

    @Test func anOldQueryCannotPublishOverTheNewQuery() async {
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID())")!
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = SearchModel(readers: [], players: [], names: PlayerNames(defaults: defaults), singleplayerUUID: nil,
                                 firstDimension: nil, savedSearches: SavedSearches(defaults: defaults),
                                 execute: { await gate.read($0.queries[0]) })
        search.text = "old"
        await gate.waitForRequest("old")
        search.text = "new"
        await gate.waitForRequest("new")
        await gate.finish("new", with: ["new": [hit("Current")]])
        await search.waitForSearch()
        await gate.finish("old", with: ["old": [hit("Obsolete")]])
        await search.waitForTasks()
        #expect(search.results.map(\.title) == ["Current"])
        #expect(search.results(for: "old").isEmpty)
        search.cancel()
    }

    @Test func sharedNameChangesReplaceTheQuerySnapshot() async {
        let defaults = UserDefaults(suiteName: "MCWorldTests-\(UUID())")!, uuid = UUID()
        let names = PlayerNames(defaults: defaults, mojang: MojangProfiles(fetch: { _ in (Data(#"{"name":"Known"}"#.utf8), 200) }))
        names.looksUpOnline = true
        let player = PlayerInfo(uuid: uuid, nbt: .compound([:]))
        let unknown = PlayerPresentation.name(of: player, singleplayerUUID: nil)
        let gate = AsyncReadGate<[String: [SearchHit]]>()
        let search = SearchModel(readers: [], players: [player], names: names, singleplayerUUID: nil, firstDimension: nil,
                                 savedSearches: SavedSearches(defaults: defaults),
                                 execute: { await gate.read($0.playerNames[uuid]!) })
        search.text = "diamond"
        await gate.waitForRequest(unknown)
        await names.lookUp([uuid])
        await gate.waitForRequest("Known")
        await gate.finish("Known", with: ["diamond": [hit("Known")]])
        await search.waitForSearch()
        await gate.finish(unknown, with: ["diamond": [hit("Unknown")]])
        await search.waitForTasks()
        #expect(search.results.map(\.title) == ["Known"])
        search.cancel()
    }
}
