import ChunkseeIndex
import ChunkseeKit
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

enum GameNameFixture {
    static func game(unluck: String = "Bad Luck") throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us",
                "effect.minecraft.unluck": unluck,
                "effect.minecraft.dolphins_grace": "Dolphin’s Grace",
                "effect.minecraft.hero_of_the_village": "Hero of the Village",
                "effect.minecraft.breath_of_the_nautilus": "Breath of the Nautilus",
                "merchant.level.1": "Novice", "merchant.level.6": "A New Rank",
                "stat.minecraft.aviate_one_cm": "Distance by Elytra",
                "stat.minecraft.play_time": "Time Played",
                "advancements.story.mine_diamond.title": "Diamonds!",
                "block.minecraft.diamond_ore": "Diamond Ore", "block.minecraft.spawner": "Monster Spawner",
                "item.test.unfamiliar_item": "A Game-Supplied Item",
                "entity.test.unfamiliar_mob": "A Game-Supplied Mob",
                "gameMode.survival": "Survival Mode", "options.difficulty.hard": "Hard",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fra_FR",
                "effect.minecraft.unluck": "Malchance", "block.minecraft.diamond_ore": "Minerai de diamant",
                "tag.block.minecraft.diamond_ores": "Diamants du pack",
                "block.minecraft.spawner": "Générateur de monstres",
            ]),
        ])
    }

    static func names(_ locale: String = "en_US") async throws -> GameNames {
        let game = try game()
        defer { game.remove() }
        return GameNames(await (try game.library()).data.language(locale, minecraftDirectory: game.root))
    }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameNamesTests {
    private func resources(_ root: URL, game: ItemPictureFixture) async throws -> WorldResources {
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        return try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
    }

    @Test func presentationUsesTranslatedNamesThenEnglishThenTheSavedID() async throws {
        let names = try await GameNameFixture.names("fr_FR")
        let effect = StatusEffect(id: "minecraft:unluck", amplifier: 1, durationTicks: 20)
        #expect(names.effect(effect) == "Malchance II")
        #expect(names.name("example:unluck", in: "effect") == "Unluck")
        #expect(names.merchantLevel(1) == "Novice")
        #expect(names.merchantLevel(6) == "A New Rank")
        #expect(names.merchantLevel(7) == "Level 7")
        #expect(names.merchantLevel(nil) == nil)
        #expect(names.name("minecraft:aviate_one_cm", in: "stat") == "Distance by Elytra")
        #expect(names.advancement("minecraft:story/mine_diamond",
            title: .translated(key: "advancements.story.mine_diamond.title", fallback: nil, arguments: [])) == "Diamonds!")
        #expect(names.advancement("example:story/mine_diamond", title: nil) == "Story Mine Diamond")
        #expect(NotableBlock.diamond.name(in: names) == "Diamants du pack")
        #expect(NotableBlock.block("minecraft:diamond_ore").name(in: names) == "Minerai de diamant")
        #expect(NotableBlock.tag("test:moon_ores").name(in: names) == "Moon Ores")
        #expect(NotableBlock.spawner.name(in: names) == "Générateur de monstres")
        #expect(names.gameMode(.survival) == "Survival Mode")
        #expect(names.name(key: "options.difficulty.hard", fallback: "Hard") == "Hard")
        let item = StatisticRow(categoryID: "minecraft:used", statisticID: "test:unfamiliar_item", value: 2)
        let mob = StatisticRow(categoryID: "minecraft:killed", statisticID: "test:unfamiliar_mob", value: 3)
        #expect(names.statistic(item) == "A Game-Supplied Item")
        #expect(names.statistic(mob) == "A Game-Supplied Mob")
        let unfamiliarCategory = StatisticRow(categoryID: "test:custom_kind", statisticID: item.statisticID, value: 3)
        #expect(names.statistic(unfamiliarCategory) == "Unfamiliar Item")
        #expect(names.statistic(StatisticRow(categoryID: "minecraft:mined", statisticID: "minecraft:diamond_ore", value: 64))
            == "Minerai de diamant")
        #expect(names.statisticCategory("minecraft:custom") == "General")
        #expect(names.statisticCategory("test:custom_kind") == "Custom Kind")
        #expect(GameNames.unavailable.name("test:new_path/new_name", in: "effect") == "New Path New Name")
    }

    @Test func difficultyKeepsSavedFlagsAndUsesTheSameLanguageFallbacks() async throws {
        let game = try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us", "options.difficulty.extreme": "Extreme Rules",
                "options.difficulty.hardcore": "One Life",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr", "options.difficulty.extreme": "Extrême",
            ]),
        ])
        defer { game.remove() }
        let names = GameNames(await (try game.library()).data.language("fr_FR", minecraftDirectory: game.root))
        #expect(names.difficulty("extreme", isHardcore: false, isLocked: false) == "Extrême")
        #expect(names.difficulty("extreme", isHardcore: true, isLocked: false) == "Extrême, One Life")
        #expect(names.difficulty("extreme", isHardcore: true, isLocked: true) == "Extrême, One Life, locked")
        #expect(names.difficulty(nil, isHardcore: false, isLocked: false) == "Unknown")
        #expect(GameNames.unavailable.difficulty("future_mode", isHardcore: false, isLocked: true) == "Future Mode, locked")
        #expect(GameNames.unavailable.difficulty(nil, isHardcore: true, isLocked: false) == "Unknown, Hardcore")
    }

    @Test func namesWithoutGameKeysKeepTheSavedWordsAndOrder() {
        for (id, expected) in [("black", "Black"), ("red", "Red"), ("all_black", "All Black")] {
            #expect(GameNames.unavailable.appearanceValue("minecraft:" + id) == expected)
        }
        #expect(ReadableName.from("minecraft:abandoned_camp_old_growth_pine_taiga") == "Abandoned Camp Old Growth Pine Taiga")
        #expect(GameNames.unavailable.lootTable("minecraft:chests/simple_dungeon") == "Simple Dungeon Loot")
        #expect(GameNames.unavailable.lootTable("minecraft:chests/jungle_temple") == "Jungle Temple Loot")
        #expect(GameNames.unavailable.lootTable("minecraft:chests/abandoned_mineshaft") == "Abandoned Mineshaft Loot")
    }

    @Test func translatedBlockSearchMatchesTheDisplayedNameAndStillAcceptsIDs() async throws {
        let names = try await GameNameFixture.names("fr_FR")
        let blocks = try BlockSearchFixture.input([BlockSearchFixture.chunk(x: 0, count: 4)])
        for query in ["block:diamants", "block:minecraft:diamond_ore"] {
            let found = WorldSearch.search(query, in: SearchIndex(), players: [], gameNames: names, blocks: blocks) { _ in .named("") }
            #expect(found.map { $0.title(in: names) } == ["Diamants du pack"])
            #expect(found.first?.count == 4)
        }
    }

    @Test func openWorldObservesLanguageChangesReplacementRemovalAndRechoice() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        let replacement = try GameNameFixture.game(unluck: "Replacement Name")
        defer { game.remove(); replacement.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshGameLanguage(preferredLanguage: "en_US")
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        _ = withObservationTracking { world.gameNames } onChange: {
            continuation.yield(true)
        }
        world.refreshGameAssets()
        await world.waitForRefresh()
        continuation.finish()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next(isolation: #isolation) == true)
        #expect(world.gameNames.name("unluck", in: "effect") == "Bad Luck")
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        #expect(world.gameNames.identity == nil)
        await world.waitForRefresh()
        #expect(world.gameNames.name("unluck", in: "effect") == "Malchance")
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        world.names.minecraft.choose(replacement.root)
        #expect(world.gameNames.identity == nil)
        await world.waitForRefresh()
        #expect(world.gameNames.name("unluck", in: "effect") == "Replacement Name")
        world.names.minecraft.forget()
        #expect(world.gameNames.name("unluck", in: "effect") == "Unluck")
        await world.waitForRefresh()
        world.names.minecraft.choose(game.root)
        await world.waitForRefresh()
        #expect(world.gameNames.name("unluck", in: "effect") == "Bad Luck")
        world.close()
        #expect(world.gameNames.identity == nil)
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func sharedSavedSearchesFollowTheWorldsNamesInEveryWindow() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone", "minecraft:spawner"]) { x, y, z in
            (x, y, z) == (1, 1, 1) ? 1 : 0
        }
        let root = try TestWorld.make(chunks: [chunk]), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game)
        defer { world.close() }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        world.savedSearches.add("block:")
        world.refreshGameLanguage(preferredLanguage: "en_US")
        world.refreshGameAssets()
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Monster Spawner"])
        }
        let identity = world.gameNames.identity
        for usesArtwork in [false, true, false] {
            world.names.minecraft.usesGameArtwork = usesArtwork
            await world.waitForRefresh()
            #expect(world.gameNames.identity == identity)
            #expect(NotableBlock.spawner.name(in: world.gameNames) == "Monster Spawner")
            for session in [first, second] {
                await session.search.waitForSearch()
                #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) }
                        == [NotableBlock.spawner.name(in: world.gameNames)])
            }
        }
        let french = await (try game.library()).data.language("fr_FR", minecraftDirectory: game.root)
        let gate = AsyncReadGate<GameLanguage?>()
        world.readLanguage = { _, _, _ in await gate.read("language") }
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        // Retired labels are ineligible even before Observation schedules the replacement query.
        #expect(first.search.results(for: "block:").isEmpty)
        await gate.waitForRequest("language")
        #expect(NotableBlock.spawner.name(in: world.gameNames) == "Spawner")
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) }
                    == [NotableBlock.spawner.name(in: world.gameNames)])
        }
        await gate.finish("language", with: french)
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Générateur de monstres"])
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) }
                    == [NotableBlock.spawner.name(in: world.gameNames)])
        }
        world.names.minecraft.forget()
        #expect(second.search.results(for: "block:").isEmpty)
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Spawner"])
        }
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func anUnchangedSourceRereadKeepsNamesAndSavedSearchesInEveryWindow() async throws {
        let chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone", "minecraft:spawner"]) { x, y, z in
            (x, y, z) == (1, 1, 1) ? 1 : 0
        }
        let root = try TestWorld.make(chunks: [chunk]), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game)
        defer { world.close() }
        let sessions = [WorldSession(resources: world), WorldSession(resources: world)]
        world.savedSearches.add("block:")
        world.refreshGameLanguage(preferredLanguage: "en_US")
        world.refreshGameAssets()
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in sessions { await session.search.waitForSearch() }
        let loaded = world.gameNames
        let gate = AsyncReadGate<GameLanguage?>(), library = try game.library()
        let reread = await library.data.language("en_US", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in await gate.read("reread") }
        world.refreshGameAssets()
        await gate.waitForRequest("reread")
        #expect(world.gameNames.identity == loaded.identity)
        #expect(world.gameNames.name("unluck", in: "effect") == "Bad Luck")
        for session in sessions {
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Monster Spawner"])
            #expect(!session.search.isSearching)
        }
        await gate.finish("reread", with: reread)
        await world.waitForRefresh()
        #expect(world.gameNames.identity == loaded.identity)
        for session in sessions {
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Monster Spawner"])
            #expect(!session.search.isSearching)
        }
        // A changed language object with the same jar still publishes new names.
        let changed = await library.data.language("fr_FR", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in changed }
        world.refreshGameAssets()
        await world.waitForRefresh()
        #expect(world.gameNames.identity != loaded.identity)
        #expect(world.gameNames.name("unluck", in: "effect") == "Malchance")
        for session in sessions {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map { $0.title(in: world.gameNames) } == ["Générateur de monstres"])
        }
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func repeatedReloadsPublishProgressAndOnlyTheLastWindowCancelsSharedNames() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game)
        let sessions = [WorldSession(resources: world), WorldSession(resources: world)]
        let gate = AsyncReadGate<GameLanguage?>(), numbers = ReadNumbers()
        var closeWaiter: Task<Void, Never>?
        func close() async {
            await gate.releaseAllAndFuture(with: nil)
            sessions.forEach { $0.close() }
            world.close()
            await world.waitUntilClosed()
            await closeWaiter?.value
            await world.names.minecraft.waitUntilIdle()
        }
        do {
            world.refreshGameLanguage(preferredLanguage: "en_US")
            await world.waitForRefresh()
            let library = try game.library()
            let english = try #require(await library.data.language("en_US", minecraftDirectory: game.root))
            let french = try #require(await library.data.language("fr_FR", minecraftDirectory: game.root))
            let original = world.gameNames.identity
            try #require(original != nil)
            world.readLanguage = { _, _, _ in await gate.read(String(await numbers.next())) }
            world.refreshGameLanguage(reload: true)
            await gate.waitForRequest("0")
            for _ in 0..<8 { world.refreshGameLanguage(reload: true) }
            #expect(world.gameNames.identity == original)
            sessions[0].close()
            try #require(!world.isClosed)

            await gate.finish("0", with: french)
            await gate.waitForRequest("1")
            // The first pass must publish before the coalesced pass finishes. Restarting every
            // reload would discard this progress and leave the previous English names showing.
            #expect(world.gameNames.name("unluck", in: "effect") == "Malchance")
            #expect(world.gameNames.identity != original)
            await gate.finish("1", with: english)
            await world.waitForRefresh()
            #expect(world.gameNames.name("unluck", in: "effect") == "Bad Luck")
            #expect(await gate.requested == ["0", "1"])

            world.refreshGameLanguage(reload: true)
            await gate.waitForRequest("2")
            sessions[1].close()
            #expect(world.isClosed && world.gameNames.identity == nil)
            var drained = false
            await withCheckedContinuation { started in
                closeWaiter = Task {
                    started.resume()
                    await world.waitUntilClosed()
                    drained = true
                }
            }
            await gate.waitForCancellation("2")
            #expect(!drained)
            await gate.finish("2", with: french)
            await closeWaiter?.value
            #expect(drained && world.gameNames.identity == nil)
        } catch {
            await close()
            throw error
        }
        await close()
    }

    @Test func anUnavailableLanguageClearsNamesAndIsReusedUntilInvalidated() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game), gate = AsyncReadGate<GameLanguage?>()
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        #expect(world.gameNames.name("unluck", in: "effect") == "Bad Luck")
        world.readLanguage = { _, _, _ in await gate.read("unavailable") }
        world.refreshGameLanguage(reload: true)
        await gate.waitForRequest("unavailable")
        await gate.releaseAllAndFuture(with: nil)
        await world.waitForRefresh()
        #expect(world.gameNames.identity == nil)
        #expect(world.gameNames.name("unluck", in: "effect") == "Unluck")
        world.refreshGameLanguage()
        await world.waitForRefresh()
        #expect(await gate.requested == ["unavailable"])
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func aLateLanguageReadCannotReplaceTheNewerPreference() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game), gate = AsyncReadGate<GameLanguage?>()
        defer { world.close() }
        await world.waitForRefresh()
        let library = try game.library()
        let english = await library.data.language("en_US", minecraftDirectory: game.root)
        let french = await library.data.language("fr_FR", minecraftDirectory: game.root)
        world.readLanguage = { _, locale, _ in await gate.read(locale) }
        // The opening already has its game source. Hold an explicit language reread without
        // introducing an unrelated game-source refresh that could start another language pass.
        world.refreshGameLanguage(preferredLanguage: "en_US", reload: true)
        await gate.waitForRequest("en_US")
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await gate.waitForRequest("fr_FR")
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        _ = withObservationTracking { world.gameNames } onChange: { continuation.yield(true) }
        await gate.finish("fr_FR", with: french)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next(isolation: #isolation) == true)
        continuation.finish()
        #expect(world.gameNames.name("unluck", in: "effect") == "Malchance")
        await gate.finish("en_US", with: english)
        await world.waitForRefresh()
        #expect(world.gameNames.name("unluck", in: "effect") == "Malchance")
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test(arguments: [false, true]) func retirementRejectsALanguageReadAlreadyUnderway(close: Bool) async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game), gate = AsyncReadGate<GameLanguage?>()
        let language = await (try game.library()).data.language("en_US", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in await gate.read("held") }
        world.refreshGameAssets()
        await gate.waitForRequest("held")
        if close { world.close() } else { world.names.minecraft.forget() }
        await gate.finish("held", with: language)
        await world.waitForRefresh()
        #expect(world.gameNames.identity == nil)
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }
}
