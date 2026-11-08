import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct AdvancementTitleTests {
    private let diamond = "minecraft:story/mine_diamond"

    private func game(title: String = "Actual %s") throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us", "test.diamond": title, "advancements.story.mine_diamond.title": "Wrong guessed key",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json(["language.code": "fr_fr", "test.diamond": "Vrais %s"]),
            "data/minecraft/advancement/story/mine_diamond.json": Data(#"{"display":{"title":{"translate":"test.diamond","with":["diamonds"]}}}"#.utf8),
            "data/test/advancement/literal.json": Data(#"{"display":{"title":{"text":"Literal title","extra":["!"]}}}"#.utf8),
            "data/test/advancement/dynamic.json": Data(#"{"display":{"title":{"selector":"@s"}}}"#.utf8),
            "data/test/advancement/missing_title.json": Data(#"{"display":{}}"#.utf8),
        ])
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func progress(at root: URL, player: UUID) throws -> [URL: Data] {
        var entries: [String: Any] = ["DataVersion": SaveVersion.java26_3]
        for (index, id) in [diamond, "test:literal", "test:dynamic", "test:missing_title", "test:unknown", "test:incomplete", "minecraft:recipes/test"].enumerated() {
            entries[id] = ["done": id != "test:incomplete", "criteria": ["found": "2026-10-\(20 - index) 12:00:00 +0000"]]
        }
        let files = [
            root.appendingPathComponent("players/advancements/\(player.uuidString.lowercased()).json"): try ItemPictureFixture.json(entries),
            root.appendingPathComponent("players/stats/\(player.uuidString.lowercased()).json"): try ItemPictureFixture.json([
                "DataVersion": SaveVersion.java26_3, "stats": ["minecraft:custom": ["minecraft:deaths": 4]],
            ]),
        ]
        for (url, data) in files { try write(data, to: url) }
        return files
    }

    private func pack(at root: URL, enabled: Bool, title: String = "Pack title") throws -> URL {
        let folder = root.appendingPathComponent("datapacks/titles")
        try write(ItemPictureFixture.json(["pack": ["min_format": 121, "max_format": 121, "description": "Title fixture"]]),
                  to: folder.appendingPathComponent("pack.mcmeta"))
        try write(ItemPictureFixture.json(["display": ["title": title]]),
                  to: folder.appendingPathComponent("data/minecraft/advancement/story/mine_diamond.json"))
        let enabledPacks = ["vanilla", TestWorldResources.pack] + (enabled ? ["file/titles"] : [])
        let metadata = root.appendingPathComponent("level.dat")
        try Fixtures.writeGzippedNBT(.compound(["Data": .compound([
            "LevelName": .string("Title fixture"), "DataVersion": .int(Int32(SaveVersion.java26_3)),
            "DataPacks": .compound(["Enabled": .list(enabledPacks.map(NBT.string))]),
        ])]), to: metadata)
        return metadata
    }

    private func resources(_ root: URL, game: ItemPictureFixture) async throws -> WorldResources {
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
        resources.refreshGameAssets()
        await resources.waitForRefresh()
        return resources
    }

    private func read(_ world: WorldResources, player: UUID) async throws -> PlayerRecords {
        let handle = try #require(world.playerRecords.acquire(player))
        defer { handle.close() }
        await world.playerRecords.waitUntilFinished()
        return try #require(handle.records)
    }

    @Test func titlesComeFromDefinitionsAndNeverFilterSavedProgress() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let files = try progress(at: root, player: player), world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        let records = try await read(world, player: player)
        let names = world.gameNames
        #expect(records.advancements.count == 7 && records.completedAdvancements.count == 5)
        #expect(records.statistics?.value("minecraft:deaths") == 4)
        #expect(names.advancement(diamond, title: records.title(for: diamond)) == "Vrais diamonds")
        #expect(records.title(for: "story/mine_diamond") == records.title(for: diamond))
        #expect(names.advancement("test:literal", title: records.title(for: "test:literal")) == "Literal title!")
        for id in ["test:dynamic", "test:missing_title", "test:unknown"] {
            #expect(records.title(for: id) == nil)
            #expect(records.completedAdvancements.contains { $0.id == id })
        }
        #expect(names.advancement(diamond, title: nil) == "Story Mine Diamond") // No invented key lookup.
        let unavailable = try await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: nil).value
        #expect(unavailable.advancements == records.advancements && unavailable.statistics == records.statistics)
        #expect(unavailable.advancementDefinitions.isEmpty)
        for (url, before) in files { #expect(try Data(contentsOf: url) == before) }
        world.close()
        await world.waitUntilClosed()
        world.names.minecraft.forget()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func packChangesUseFreshMetadataWithoutReplacingTheSavedWorld() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let files = try progress(at: root, player: player), world = try World(contentsOf: root), library = try game.library().data
        _ = try pack(at: root, enabled: true)
        let packed = try await PlayerRecords.load(from: world, uuid: player, name: nil, library: library).value
        #expect(packed.advancementDefinitions[diamond]?.title == .literal("Pack title"))
        let withoutGame = try await PlayerRecords.load(from: world, uuid: player, name: nil, library: nil).value
        #expect(withoutGame.advancementDefinitions[diamond]?.title == .literal("Pack title"))
        _ = try pack(at: root, enabled: false)
        let restored = try await PlayerRecords.load(from: world, uuid: player, name: nil, library: library).value
        let names = GameNames(await library.language("en_US", minecraftDirectory: game.root))
        #expect(names.advancement(diamond, title: restored.advancementDefinitions[diamond]?.title) == "Actual diamonds")
        #expect(restored.advancements == packed.advancements && packed.advancements == withoutGame.advancements)
        for (url, before) in files { #expect(try Data(contentsOf: url) == before) }
        await library.close()
    }

    @Test func savedCatalogsLargerThanTheDefinitionLimitKeepTheirVisibleTitles() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        var entries: [String: Any] = [diamond: ["done": true, "criteria": ["found": "2026-10-20 12:00:00 +0000"]]]
        for index in 0..<4096 { entries["test:extra_\(index)"] = ["done": true, "criteria": [:]] }
        try write(ItemPictureFixture.json(entries), to: root.appendingPathComponent("advancements/\(player.uuidString.lowercased()).json"))
        let library = try game.library().data
        let records = try await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: library).value
        #expect(records.completedAdvancements.count == 4097)
        #expect(records.completedAdvancements.first?.id == diamond)
        #expect(records.advancementDefinitions[diamond]?.title != nil)
        await library.close()
    }

    @Test func onlyTheDisplayedAdvancementsLoadDefinitionsWhileAllProgressRemains() async throws {
        let root = try TestWorld.make(chunks: []), player = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["oldest", "second", "third", "fourth", "fifth", "newest"]
        var files: [String: Data] = [:], saved: [String: Any] = ["DataVersion": SaveVersion.java26_3]
        for (index, name) in names.enumerated() {
            files["data/test/advancement/\(name).json"] = try ItemPictureFixture.json(["display": ["title": name]])
            saved["test:" + name] = ["done": true, "criteria": ["found": "2026-10-\(10 + index) 12:00:00 +0000"]]
        }
        let game = try ItemPictureFixture(extraFiles: files), library = try game.library().data
        defer { game.remove() }
        try write(ItemPictureFixture.json(saved), to: root.appendingPathComponent("players/advancements/\(player.uuidString.lowercased()).json"))
        let records = try await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: library).value
        let expected = ["test:newest", "test:fifth", "test:fourth", "test:third", "test:second"]
        #expect(records.completedAdvancements.count == 6)
        #expect(records.displayedAdvancements.map(\.id) == expected)
        #expect(Set(records.advancementDefinitions.keys) == Set(expected))
        #expect(records.advancementDefinitions["test:oldest"] == nil)
        await library.close()
    }

    @Test func titlesAndProgressRemainAvailableWhenArtworkChanges() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        _ = try progress(at: root, player: player)
        let world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        let readRecords = world.playerRecords.read, calls = ReadNumbers()
        world.playerRecords.read = { source, uuid, name, library, previous in
            _ = await calls.next()
            return try await readRecords(source, uuid, name, library, previous)
        }
        let handle = try #require(world.playerRecords.acquire(player))
        await world.playerRecords.waitUntilFinished()
        let original = try #require(handle.records)
        let namesIdentity = world.gameNames.identity
        for usesArtwork in [false, true, false] {
            world.names.minecraft.usesGameArtwork = usesArtwork
            await world.waitForRefresh()
            let records = try #require(handle.records)
            #expect(world.gameNames.identity == namesIdentity)
            #expect(records.advancements == original.advancements && records.statistics == original.statistics)
            #expect(PlayerRecords.advancementName(diamond, title: records.title(for: diamond),
                                                 gameNames: world.gameNames) == "Actual diamonds")
        }
        #expect(await calls.next() == 1)
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func autosaveAndTitleOnlyPackEditsRetainTitlesUntilCompletedContentArrives() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        _ = try progress(at: root, player: player)
        let world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshDelay = .zero
        let handle = try #require(world.playerRecords.acquire(player))
        await world.waitForRefresh()
        let original = try #require(handle.records), originalDefinitions = world.details.definitions
        let gate = AsyncReadGate<Result<Void, CocoaError>>(), numbers = ReadNumbers()
        world.playerRecords.read = { source, uuid, name, library, previous in
            try await gate.read(String(await numbers.next())).get()
            return try await PlayerRecords.load(from: source, uuid: uuid, name: name, library: library, previous: previous)
        }
        world.worldChanged([root.appendingPathComponent("level.dat")])
        await gate.waitForRequest("0")
        #expect(handle.records == original)
        #expect(handle.records?.title(for: diamond) == original.title(for: diamond))
        await gate.finish("0", with: .failure(CocoaError(.fileReadUnknown)))
        await world.waitForRefresh()
        #expect(handle.records == original)
        world.worldChanged([root.appendingPathComponent("level.dat")])
        await gate.waitForRequest("1")
        #expect(handle.records == original)
        await gate.finish("1", with: .success(()))
        await world.waitForRefresh()
        #expect(handle.records == original)

        let metadata = try pack(at: root, enabled: true)
        world.worldChanged([metadata])
        await gate.waitForRequest("2")
        #expect(handle.records == original)
        await gate.finish("2", with: .success(()))
        await world.waitForRefresh()
        #expect(handle.records?.title(for: diamond) == .literal("Pack title"))
        let packed = try #require(handle.records)
        _ = try pack(at: root, enabled: true, title: "Changed pack title")
        world.worldChanged([root.appendingPathComponent("datapacks/titles/data/minecraft/advancement/story/mine_diamond.json")])
        await gate.waitForRequest("3")
        #expect(handle.records == packed)
        await gate.finish("3", with: .success(()))
        await world.waitForRefresh()
        #expect(world.details.definitions == originalDefinitions)
        #expect(handle.records?.title(for: diamond) == .literal("Changed pack title"))
        #expect(handle.records?.advancements == original.advancements)
        #expect(handle.records?.statistics == original.statistics)
        world.close(); await world.waitUntilClosed()
    }

    @Test func sourceReplacementAndWorldClosureRejectLateReadsAndRetireIncompatibleTitles() async throws {
        let root = try TestWorld.make(chunks: []), first = try game(), second = try game(title: "Replacement %s"), player = UUID()
        defer { first.remove(); second.remove(); try? FileManager.default.removeItem(at: root) }
        _ = try progress(at: root, player: player)
        let world = try await resources(root, game: first), gate = AsyncReadGate<Void>(), numbers = ReadNumbers()
        defer { world.close() }
        world.refreshDelay = .zero
        world.playerRecords.read = { source, uuid, name, library, previous in
            let records = try await PlayerRecords.load(from: source, uuid: uuid, name: name, library: library, previous: previous)
            await gate.read(String(await numbers.next()))
            return records
        }
        let handle = try #require(world.playerRecords.acquire(player))
        await gate.waitForRequest("0")
        world.names.minecraft.choose(second.root)
        await gate.waitForCancellation("0")
        await gate.waitForRequest("1")
        await gate.finish("1", with: ())
        for await records in Observations({ handle.records }) where records != nil { break }
        let current = try #require(handle.records)
        await gate.finish("0", with: ())
        await world.waitForRefresh()
        #expect(handle.records == current)
        world.names.minecraft.forget()
        #expect(handle.records?.advancementDefinitions.isEmpty == true)
        #expect(handle.records?.advancements == current.advancements)
        await gate.waitForRequest("2")
        await gate.finish("2", with: ())
        await world.waitForRefresh()
        #expect(handle.records?.advancementDefinitions.isEmpty == true)
        #expect(handle.records?.statistics == current.statistics)

        world.worldChanged([try pack(at: root, enabled: true)])
        await gate.waitForRequest("3"); await gate.finish("3", with: ())
        await world.waitForRefresh()
        #expect(handle.records?.title(for: diamond) == .literal("Pack title"))
        world.worldChanged([root.appendingPathComponent("level.dat")])
        await gate.waitForRequest("4")
        world.close()
        await gate.waitForCancellation("4"); await gate.finish("4", with: ())
        await world.waitUntilClosed()
        #expect(handle.records == nil && world.playerRecords.acquire(player) == nil)
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func failedFilesKeepTheirFactsWhileSuccessfulEmptyReadsRemoveThem() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let files = try progress(at: root, player: player), world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshDelay = .zero
        let handle = try #require(world.playerRecords.acquire(player))
        await world.waitForRefresh()
        let original = try #require(handle.records)
        let stats = try #require(files.keys.first { $0.path.contains("/stats/") })
        let advancements = try #require(files.keys.first { $0.path.contains("/advancements/") })
        try write(ItemPictureFixture.json(["stats": ["minecraft:custom": ["minecraft:deaths": 9]]]), to: stats)
        try write(Data("{".utf8), to: advancements)
        world.worldChanged([stats, advancements]); await world.waitForRefresh()
        #expect(handle.records?.statistics?.value("minecraft:deaths") == 9)
        #expect(handle.records?.advancements == original.advancements)
        #expect(handle.records?.title(for: diamond) == original.title(for: diamond))
        try FileManager.default.removeItem(at: stats)
        try FileManager.default.removeItem(at: advancements)
        world.worldChanged([stats, advancements]); await world.waitForRefresh()
        #expect(handle.records?.statistics == nil && handle.records?.advancements.isEmpty == true)
        #expect(handle.records?.advancementDefinitions.isEmpty == true)
        world.close(); await world.waitUntilClosed()
    }
}
