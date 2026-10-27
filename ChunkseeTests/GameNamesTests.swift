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
                "effect.minecraft.unluck": "Malchance", "block.minecraft.diamond_ore": "Minerai de diamant",
                "block.minecraft.spawner": "Générateur de monstres",
            ]),
        ])
    }

    static func names(_ locale: String = "en_US") async throws -> GameNames {
        let game = try game()
        defer { game.remove() }
        return GameNames(await (try game.library()).language(locale, minecraftDirectory: game.root))
    }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameNamesTests {
    private func resources(_ root: URL, game: ItemPictureFixture) async throws -> WorldResources {
        let defaults = TestDefaults.make(), names = PlayerNames(defaults: TestDefaults.make())
        names.minecraft.choose(game.root)
        return try WorldResources(snapshot: try await WorldSnapshot.read(root), names: names,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
            watchWorld: { _, _ in nil })
    }

    @Test func presentationUsesTranslatedNamesThenEnglishThenTheSavedID() async throws {
        let names = try await GameNameFixture.names("fr_FR")
        let effect = StatusEffect(id: "minecraft:unluck", amplifier: 1, durationTicks: 20)
        #expect(PlayerEffectText.name(effect, gameNames: names) == "Malchance II")
        #expect(names.name("example:unluck", in: "effect") == "Unluck")
        #expect(VillagerText.levelName(1, gameNames: names) == "Novice")
        #expect(VillagerText.levelName(6, gameNames: names) == "A New Rank")
        #expect(VillagerText.levelName(7, gameNames: names) == "Level 7")
        #expect(PlayerRecords.travelName("minecraft:aviate_one_cm", gameNames: names) == "Distance by Elytra")
        #expect(PlayerRecords.advancementName("minecraft:story/mine_diamond",
            title: .translated(key: "advancements.story.mine_diamond.title", fallback: nil, arguments: []), gameNames: names) == "Diamonds!")
        #expect(PlayerRecords.advancementName("example:story/mine_diamond", gameNames: names) == "Story Mine Diamond")
        #expect(NotableBlock.diamond.name(in: names) == "Minerai de diamant")
        #expect(NotableBlock.spawner.name(in: names) == "Générateur de monstres")
        #expect(names.gameMode(.survival) == "Survival Mode")
        #expect(names.name(key: "options.difficulty.hard", fallback: "Hard") == "Hard")
        let item = StatisticRow(categoryID: "minecraft:used", statisticID: "test:unfamiliar_item", value: 2)
        let mob = StatisticRow(categoryID: "minecraft:killed", statisticID: "test:unfamiliar_mob", value: 3)
        #expect(item.name(in: names) == "A Game-Supplied Item")
        #expect(mob.name(in: names) == "A Game-Supplied Mob")
        let unfamiliarCategory = StatisticRow(categoryID: "test:custom_kind", statisticID: item.statisticID, value: 3)
        #expect(unfamiliarCategory.name(in: names) == "Unfamiliar Item")
        #expect(GameNames().name("test:new_path/new_name", in: "effect") == "New Path New Name")
    }

    @Test func namesWithoutGameKeysKeepTheSavedWordsAndOrder() {
        for (id, expected) in [("black", "Black"), ("red", "Red"), ("all_black", "All Black")] {
            #expect(PetDetailText.name("minecraft:" + id) == expected)
        }
        #expect(ReadableName.from("minecraft:abandoned_camp_old_growth_pine_taiga") == "Abandoned Camp Old Growth Pine Taiga")
        #expect(LootTableName.name("minecraft:chests/simple_dungeon") == "Simple Dungeon Loot")
        #expect(LootTableName.name("minecraft:chests/jungle_temple") == "Jungle Temple Loot")
        #expect(LootTableName.name("minecraft:chests/abandoned_mineshaft") == "Abandoned Mineshaft Loot")
    }

    @Test func translatedBlockSearchMatchesTheDisplayedNameAndStillAcceptsIDs() async throws {
        let names = try await GameNameFixture.names("fr_FR")
        let deposit = ChunkDeposit(chunk: ChunkPosition(x: 0, z: 0),
            deposit: BlockDeposit(block: .diamond, count: 4, minY: 0, maxY: 15))
        let index = SearchIndex.overworld(DimensionContent(blocks: [deposit]))
        for query in ["block:minerai", "block:minecraft:diamond_ore"] {
            let found = WorldSearch.search(query, in: index, players: [], gameNames: names) { _ in .named("") }
            #expect(found.map(\.title) == ["Minerai de diamant"])
            #expect(found.first?.count == 4)
        }
    }

    @Test func openWorldObservesLanguageChangesReplacementRemovalAndRechoice() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        let replacement = try GameNameFixture.game(unluck: "Replacement Name")
        defer { game.remove(); replacement.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game)
        defer { world.close() }
        world.refreshGameLanguage(locale: Locale(identifier: "en_US"))
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        _ = withObservationTracking { world.gameNames(for: Locale(identifier: "en_US")) } onChange: {
            continuation.yield(true)
        }
        world.refreshGameAssets()
        await world.waitForRefresh()
        continuation.finish()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next(isolation: #isolation) == true)
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Bad Luck")
        world.refreshGameLanguage(locale: Locale(identifier: "fr_FR"))
        #expect(world.gameNames(for: Locale(identifier: "en_US")).identity == nil)
        await world.waitForRefresh()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Malchance")
        world.refreshGameLanguage(locale: Locale(identifier: "en_US"))
        await world.waitForRefresh()
        world.names.minecraft.choose(replacement.root)
        #expect(world.currentGameNames.identity == nil)
        await world.waitForRefresh()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Replacement Name")
        world.names.minecraft.forget()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Unluck")
        await world.waitForRefresh()
        world.names.minecraft.choose(game.root)
        await world.waitForRefresh()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Bad Luck")
        world.close()
        #expect(world.currentGameNames.identity == nil)
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
        world.refreshGameLanguage(locale: Locale(identifier: "en_US"))
        world.refreshGameAssets()
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map(\.title) == ["Monster Spawner"])
        }
        world.refreshGameLanguage(locale: Locale(identifier: "fr_FR"))
        // Retired labels are ineligible even before Observation schedules the replacement query.
        #expect(first.search.results(for: "block:").isEmpty)
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map(\.title) == ["Générateur de monstres"])
        }
        world.names.minecraft.forget()
        #expect(second.search.results(for: "block:").isEmpty)
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map(\.title) == ["Spawner"])
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
        world.refreshGameLanguage(locale: Locale(identifier: "en_US"))
        world.refreshGameAssets()
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in sessions { await session.search.waitForSearch() }
        let loaded = world.currentGameNames
        let gate = AsyncReadGate<GameLanguage?>(), library = try game.library()
        let reread = await library.language("en_US", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in await gate.read("reread") }
        world.refreshGameAssets()
        await gate.waitForRequest("reread")
        #expect(world.currentGameNames.identity == loaded.identity)
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Bad Luck")
        for session in sessions {
            #expect(session.search.results(for: "block:").map(\.title) == ["Monster Spawner"])
            #expect(!session.search.isSearching)
        }
        await gate.finish("reread", with: reread)
        await world.waitForRefresh()
        #expect(world.currentGameNames.identity == loaded.identity)
        for session in sessions {
            #expect(session.search.results(for: "block:").map(\.title) == ["Monster Spawner"])
            #expect(!session.search.isSearching)
        }
        // A changed language object with the same jar still publishes new names.
        let changed = await library.language("fr_FR", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in changed }
        world.refreshGameAssets()
        await world.waitForRefresh()
        #expect(world.currentGameNames.identity != loaded.identity)
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Malchance")
        for session in sessions {
            await session.search.waitForSearch()
            #expect(session.search.results(for: "block:").map(\.title) == ["Générateur de monstres"])
        }
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test func aLateLanguageReadCannotReplaceTheNewerLocale() async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game), gate = AsyncReadGate<GameLanguage?>()
        defer { world.close() }
        let library = try game.library()
        let english = await library.language("en_US", minecraftDirectory: game.root)
        let french = await library.language("fr_FR", minecraftDirectory: game.root)
        world.readLanguage = { _, locale, _ in await gate.read(locale) }
        world.refreshGameLanguage(locale: Locale(identifier: "en_US"))
        world.refreshGameAssets()
        await gate.waitForRequest("en_US")
        world.refreshGameLanguage(locale: Locale(identifier: "fr_FR"))
        await gate.waitForRequest("fr_FR")
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        _ = withObservationTracking { world.currentGameNames } onChange: { continuation.yield(true) }
        await gate.finish("fr_FR", with: french)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next(isolation: #isolation) == true)
        continuation.finish()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Malchance")
        await gate.finish("en_US", with: english)
        await world.waitForRefresh()
        #expect(world.currentGameNames.name("unluck", in: "effect") == "Malchance")
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }

    @Test(arguments: [false, true]) func retirementRejectsALanguageReadAlreadyUnderway(close: Bool) async throws {
        let root = try TestWorld.make(chunks: []), game = try GameNameFixture.game()
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let world = try await resources(root, game: game), gate = AsyncReadGate<GameLanguage?>()
        let language = await (try game.library()).language("en_US", minecraftDirectory: game.root)
        world.readLanguage = { _, _, _ in await gate.read("held") }
        world.refreshGameAssets()
        await gate.waitForRequest("held")
        if close { world.close() } else { world.names.minecraft.forget() }
        await gate.finish("held", with: language)
        await world.waitForRefresh()
        #expect(world.currentGameNames.identity == nil)
        world.close()
        await world.waitUntilClosed()
        await world.names.minecraft.waitUntilIdle()
    }
}
