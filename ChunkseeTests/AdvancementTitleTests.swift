import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
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

    @Test func titlesComeFromDefinitionsAndNeverFilterSavedProgress() async throws {
        let root = try TestWorld.make(chunks: []), game = try game(), player = UUID()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let files = try progress(at: root, player: player), world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        let records = try #require(await world.playerRecords(for: player, name: nil))
        let names = world.gameNames, generation = world.definitionReadGeneration
        #expect(records.advancements.count == 7 && records.completedAdvancements.count == 5)
        #expect(records.statistics?.value("minecraft:deaths") == 4)
        #expect(names.advancement(diamond, title: records.title(for: diamond, generation: generation)) == "Vrais diamonds")
        #expect(records.title(for: "story/mine_diamond", generation: generation) == records.title(for: diamond, generation: generation))
        #expect(names.advancement("test:literal", title: records.title(for: "test:literal", generation: generation)) == "Literal title!")
        for id in ["test:dynamic", "test:missing_title", "test:unknown"] {
            #expect(records.title(for: id, generation: generation) == nil)
            #expect(records.completedAdvancements.contains { $0.id == id })
        }
        #expect(names.advancement(diamond, title: nil) == "Story Mine Diamond") // No invented key lookup.
        var unowned = records
        unowned.definitionGeneration = nil
        #expect(unowned.title(for: diamond, generation: generation) == nil)
        #expect(records.title(for: diamond, generation: generation + 1) == nil)
        let unavailable = await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: nil)
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
        let packed = await PlayerRecords.load(from: world, uuid: player, name: nil, library: library)
        #expect(packed.advancementDefinitions[diamond]?.title == .literal("Pack title"))
        let withoutGame = await PlayerRecords.load(from: world, uuid: player, name: nil, library: nil)
        #expect(withoutGame.advancementDefinitions[diamond]?.title == .literal("Pack title"))
        _ = try pack(at: root, enabled: false)
        let restored = await PlayerRecords.load(from: world, uuid: player, name: nil, library: library)
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
        let records = await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: library)
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
        let records = await PlayerRecords.load(from: try World(contentsOf: root), uuid: player, name: nil, library: library)
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
        let original = try #require(await world.playerRecords(for: player, name: nil))
        let generation = world.definitionReadGeneration, namesIdentity = world.gameNames.identity
        for usesArtwork in [false, true, false] {
            world.names.minecraft.usesGameArtwork = usesArtwork
            await world.waitForRefresh()
            let records = try #require(await world.playerRecords(for: player, name: nil))
            #expect(world.definitionReadGeneration == generation && world.gameNames.identity == namesIdentity)
            #expect(records.advancements == original.advancements && records.statistics == original.statistics)
            #expect(PlayerRecords.advancementName(diamond, title: records.title(for: diamond, generation: generation),
                                                 gameNames: world.gameNames) == "Actual diamonds")
        }
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func obsoleteReadsCannotPublishAfterSourcePackOrWorldChanges() async throws {
        let root = try TestWorld.make(chunks: []), first = try game(), second = try game(title: "Replacement %s"), player = UUID()
        defer { first.remove(); second.remove(); try? FileManager.default.removeItem(at: root) }
        _ = try progress(at: root, player: player)
        let world = try await resources(root, game: first), gate = AsyncReadGate<Void>(), numbers = ReadNumbers()
        defer { world.close() }
        world.readPlayerRecords = { source, uuid, name, library in
            let records = await PlayerRecords.load(from: source, uuid: uuid, name: name, library: library)
            await gate.read(String(await numbers.next()))
            return records
        }
        let original = Task { await world.playerRecords(for: player, name: nil) }
        await gate.waitForRequest("0")
        let initialGeneration = world.definitionReadGeneration
        world.names.minecraft.choose(second.root)
        await world.waitForRefresh()
        #expect(world.definitionReadGeneration != initialGeneration)
        await gate.finish("0", with: ())
        #expect(await original.value == nil)

        let replacement = Task { await world.playerRecords(for: player, name: nil) }
        await gate.waitForRequest("1")
        world.names.minecraft.forget()
        await world.waitForRefresh()
        await gate.finish("1", with: ())
        #expect(await replacement.value == nil)

        let removed = Task { await world.playerRecords(for: player, name: nil) }
        await gate.waitForRequest("2")
        let metadata = try pack(at: root, enabled: true)
        world.worldChanged([metadata])
        await world.waitForRefresh()
        await gate.finish("2", with: ())
        #expect(await removed.value == nil)

        let packed = Task { await world.playerRecords(for: player, name: nil) }
        await gate.waitForRequest("3")
        await gate.finish("3", with: ())
        let current = try #require(await packed.value)
        #expect(current.title(for: diamond, generation: world.definitionReadGeneration) == .literal("Pack title"))
        _ = try pack(at: root, enabled: true, title: "Changed pack title")
        world.worldChanged([root.appendingPathComponent("datapacks/titles/data/minecraft/advancement/story/mine_diamond.json")])
        await world.waitForRefresh()
        #expect(current.title(for: diamond, generation: world.definitionReadGeneration) == nil)
        #expect(current.completedAdvancements.count == 5 && current.statistics?.value("minecraft:deaths") == 4)

        let closing = Task { await world.playerRecords(for: player, name: nil) }
        await gate.waitForRequest("4")
        world.close()
        await gate.finish("4", with: ())
        #expect(await closing.value == nil)
        #expect(await world.playerRecords(for: player, name: nil) == nil)
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }
}
