import ChunkseeIndex
import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GameCreatureNamesTests {
    private func game() throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us",
                "entity.minecraft.sheep": "Sheep", "entity.test.sheep": "Sheep",
                "entity.minecraft.wolf": "Wolf", "entity.minecraft.cat": "Cat",
                "entity.minecraft.villager": "Villager", "entity.minecraft.villager.farmer": "Farmer",
                "entity.minecraft.villager.none": "Villager", "entity.minecraft.zombie_villager": "Zombie Villager",
                "entity.minecraft.tropical_fish.type.kob": "Kob",
                "entity.test.keepers.hive": "Apiary Creature",
                "entity.test.villager.keepers/hive": "Apiary Keeper",
                "entity.test.villager.keepers.hive": "Wrong Profession Key",
                "merchant.level.1": "Novice", "color.minecraft.red": "Red",
                "color.minecraft.white": "White", "color.minecraft.black": "Black",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr",
                "entity.minecraft.sheep": "Mouton", "entity.test.sheep": "Brebis du pack",
                "entity.minecraft.wolf": "Loup", "entity.minecraft.cat": "Chat",
                "entity.minecraft.villager": "Villageois", "entity.minecraft.villager.farmer": "Fermier",
                "entity.minecraft.villager.none": "Villageois", "entity.minecraft.zombie_villager": "Zombie-villageois",
                "entity.minecraft.tropical_fish.type.kob": "Téraglin",
                "entity.test.villager.keepers/hive": "Apiculteur",
                "color.minecraft.red": "Rouge", "color.minecraft.white": "Blanc",
                "color.minecraft.black": "Noir",
            ]),
            "assets/minecraft/lang/is_is.json": ItemPictureFixture.json([
                "language.code": "is_is",
                "entity.minecraft.villager": "Þorpari", "entity.minecraft.villager.none": "Þorpsbúi",
            ]),
        ])
    }

    private func names(_ locale: String) async throws -> GameNames {
        let game = try game()
        defer { game.remove() }
        return GameNames(await (try game.library()).data.language(locale, minecraftDirectory: game.root))
    }

    private func marker(_ id: String, x: Double, customName: String? = nil,
                        appearance: CreatureAppearance? = nil) throws -> CreatureMarker {
        try #require(CreatureMarker(Creature(id: id, x: x, y: 64, z: 0, customName: customName,
                                           appearance: appearance), dimension: "minecraft:overworld"))
    }

    @Test func entityAndProfessionKeysFollowTheGameWhileCustomNamesStayLiteral() async throws {
        let names = try await names("fr_FR")
        let farmer = try VillagerTextTests().creature()
        #expect(names.creature(farmer) == "Fermier")
        #expect(names.profession(of: farmer, definitions: nil) == "Fermier, Novice")
        let keeper = try VillagerTextTests().creature(profession: "test:keepers/hive")
        #expect(names.creature(keeper) == "Apiculteur")
        #expect(names.profession(of: keeper, definitions: nil) == "Apiculteur, Novice")
        // EntityType uses a dotted path; VillagerProfession preserves its literal slash.
        #expect(names.entity("test:keepers/hive") == "Apiary Creature")
        #expect(names.entity("other:keepers/hive") == "Keepers Hive")
        var named = keeper
        named.customName = #"{"text":"Keep this literally"}"#
        #expect(names.creature(named) == named.customName)
        #expect(names.profession(of: named, definitions: nil) == "Apiculteur, Novice")
        #expect(names.creature(try VillagerTextTests().creature(profession: "minecraft:none")) == "Villageois")
        #expect(GameNames.unavailable.creature(farmer) == "Farmer")
        #expect(names.creature(try marker("unknown:future_creature", x: 1).creature) == "Future Creature")
    }

    @Test func zombieVillagersKeepTheirEntityNameAndSearchableProfession() async throws {
        let names = try await names("fr_FR")
        let zombie = try VillagerTextTests().creature(kind: "minecraft:zombie_villager")
        #expect(names.creature(zombie) == "Zombie-villageois")
        #expect(names.profession(of: zombie, definitions: nil) == "Fermier, Novice")
        #expect(names.creatureSearchText(zombie).contains("Fermier"))
        #expect(names.creatureSearchText(zombie).contains("minecraft:farmer"))
        let marker = try #require(CreatureMarker(zombie, dimension: "minecraft:overworld"))
        let index = SearchIndex.overworld(DimensionContent(mobTypes: MobTypes([marker])))
        for query in ["creature:fermier", "creature:zombie", "creature:minecraft:farmer"] {
            let hits = WorldSearch.search(query, in: index, players: [], gameNames: names) { _ in .named("") }
            #expect(hits.map { $0.title(in: names) } == ["Zombie-villageois"])
            #expect(hits.first?.position == marker.position)
        }
        var content = MapContent(gameNames: names)
        content.creatures = [marker]
        content.shownMobTypes = [zombie.id]
        let locations = content.accessibleLocations(viewport: MapViewport(center: marker.position, scale: 1),
                                                     size: CGSize(width: 100, height: 100))
        #expect(locations.map(\.name) == ["Zombie-villageois"])
        var named = zombie
        named.customName = "Keep this literally"
        #expect(names.creature(named) == named.customName)
        #expect(names.profession(of: named, definitions: nil) == "Fermier, Novice")
    }

    @Test func joblessVillagersUseTheirDistinctGameNameWhileProfessionStaysNone() async throws {
        let names = try await names("is_IS")
        for id in ["minecraft:none", "none", ":none"] {
            let saved = try VillagerTextTests().creature(profession: id, offers: false)
            #expect(names.creature(saved) == "Þorpsbúi")
            #expect(names.entity(saved.id) == "Þorpari")
            #expect(names.profession(of: saved, definitions: nil, locale: Locale(identifier: "en_US")) == "None")
            #expect(GameNames.unavailable.creature(saved) == "Villager")
        }
    }

    @Test func interpretedVillagerDataReachesNamesSearchAndMapAccessibility() async throws {
        let names = try await names("is_IS")
        let cases: [(String, NBT?, String, String?)] = [
            ("minecraft:villager", nil, "Þorpsbúi", "None"),
            ("minecraft:villager", .string("unreadable"), "Þorpsbúi", "None"),
            ("minecraft:villager", .compound(["profession": .int(7)]), "Þorpsbúi", "None"),
            ("minecraft:villager", .compound(["profession": .string("")]), "Þorpari", nil),
            ("minecraft:zombie_villager", nil, "Zombie Villager", nil),
            ("minecraft:villager", .compound([
                "profession": .string("test:keepers/hive"), "level": .int(0),
            ]), "Apiary Keeper", "Apiary Keeper, Novice"),
        ]
        for (kind, data, expectedName, expectedProfession) in cases {
            var fields: [String: NBT] = [
                "id": .string(kind), "Pos": .list([.double(2), .double(64), .double(3)]),
            ]
            fields["VillagerData"] = data
            let saved = try #require(Creature(Fixtures.mob(fields)))
            let original = try #require(saved.villager?.savedData)
            #expect(original.value == data && original.entityID == kind)
            #expect(names.creature(saved) == expectedName)
            #expect(names.profession(of: saved, definitions: nil, locale: Locale(identifier: "en_US")) == expectedProfession)

            let marker = try #require(CreatureMarker(saved, dimension: "minecraft:overworld"))
            let index = SearchIndex.overworld(DimensionContent(mobTypes: MobTypes([marker])))
            let hits = WorldSearch.search("creature:\(expectedName)", in: index, players: [], gameNames: names) { _ in .named("") }
            #expect(hits.map { $0.title(in: names) } == [expectedName])
            #expect(hits.first?.position == marker.position)
            var content = MapContent(gameNames: names)
            content.creatures = [marker]
            let locations = content.accessibleLocations(viewport: MapViewport(center: marker.position, scale: 1),
                                                         size: CGSize(width: 100, height: 100))
            #expect(locations.map(\.name) == [expectedName])
        }
    }

    @Test func dyeNamesDoNotRenameGenericAppearanceIDsOrDiscardTraits() async throws {
        let names = try await names("fr_FR"), locale = Locale(identifier: "en_US")
        #expect(names.dyeColor("red") == "Rouge" && names.dyeColor("minecraft:white") == "Blanc")
        #expect(names.dyeColor("test:white") == "White")
        let cat = CreatureAppearance(variant: "minecraft:black")
        #expect(names.creatureAppearance(cat, for: "minecraft:cat", locale: locale) == "Black")
        let fish = CreatureAppearance(variant: "minecraft:kob", markings: "test:striped",
            traits: ["base_color": "white", "pattern_color": "red", "main_gene": "black"])
        let label = names.creatureAppearance(fish, for: "minecraft:tropical_fish", locale: locale)
        #expect(label.contains("Téraglin") && label.contains("Striped"))
        #expect(label.contains("Base Color: Blanc") && label.contains("Pattern Color: Rouge"))
        #expect(label.contains("Main Gene: Black") && !label.contains("Noir"))
        #expect(names.creatureAppearance(MobAppearance(nil).saved, for: "minecraft:tropical_fish", locale: locale) == "Not recorded")
        #expect(names.creatureAppearance(.init(variant: "test:kob"), for: "minecraft:tropical_fish", locale: locale) == "Kob")
        #expect(names.creatureAppearance(.init(variant: "minecraft:kob"), for: "test:fish", locale: locale) == "Kob")
        #expect(names.creatureAppearance(.init(variant: "minecraft:future_pattern"), for: "minecraft:tropical_fish", locale: locale) == "Future Pattern")
        #expect(GameNames.unavailable.creatureAppearance(.init(variant: "minecraft:kob"), for: "minecraft:tropical_fish", locale: locale) == "Kob")
        let sheep = try marker("minecraft:sheep", x: 1, appearance: .init(variant: "minecraft:white"))
        #expect(names.spokenCreature(sheep.creature, locale: locale) == "White Mouton")
    }

    @Test func languageChangesKindOrderingAndCollisionLabelsWithoutChangingTheCatalog() async throws {
        let english = try await names("en_US"), french = try await names("fr_FR")
        let white = try marker("minecraft:sheep", x: 5, appearance: .init(variant: "minecraft:white"))
        let red = try marker("minecraft:sheep", x: 1, appearance: .init(variant: "minecraft:red"))
        let pack = try marker("test:sheep", x: 2), wolf = try marker("minecraft:wolf", x: 3)
        let catalog = MobTypes([white, red, pack, wolf])
        let before = english.mobKinds(in: catalog), after = french.mobKinds(in: catalog)
        #expect(before.map(\.id) == ["minecraft:sheep", "test:sheep", "minecraft:wolf"])
        #expect(before.map(\.name) == ["Sheep (minecraft:sheep)", "Sheep (test:sheep)", "Wolf"])
        #expect(after.map(\.id) == ["test:sheep", "minecraft:wolf", "minecraft:sheep"])
        #expect(after.map(\.name) == ["Brebis du pack", "Loup", "Mouton"])
        for (names, rows) in [(english, before), (french, after)] {
            for row in rows {
                #expect(names.mobName(row.id, in: catalog) == row.name)
                #expect(row.kind.count == catalog.kind(row.id)?.count)
                #expect(row.kind.variants.map(\.appearance) == catalog.kind(row.id)?.variants.map(\.appearance))
            }
        }
        #expect(catalog.kinds.reduce(0) { $0 + $1.count } == 4)
        #expect(try await catalog.nearest("minecraft:sheep", to: .zero) == [red, white])
        #expect(catalog.marker(pack.id) == pack)
    }

    @Test func creatureQueriesFindTranslatedTypesProfessionsAndRawIDs() async throws {
        let names = try await names("fr_FR")
        let wolf = try marker("minecraft:wolf", x: 1, customName: "Berry")
        var keeper = try VillagerTextTests().creature(profession: "test:keepers/hive")
        keeper.customName = "Bob"
        let villager = try #require(CreatureMarker(keeper, dimension: "minecraft:overworld"))
        let catalog = MobTypes([wolf, villager])
        let index = SearchIndex.overworld(DimensionContent(mobTypes: catalog))
        for query in ["loup", "minecraft:wolf", "creature:loup", "creature:minecraft:wolf"] {
            let hits = WorldSearch.search(query, in: index, players: [], gameNames: names) { _ in .named("") }
            #expect(hits.map { $0.title(in: names) } == ["Berry"] && hits.map { $0.detail(in: names) } == ["Loup"])
            #expect(hits.first?.position == wolf.position && hits.first?.count == 1)
        }
        for query in ["creature:apiculteur", "villager:test:keepers/hive", "apiculteur"] {
            let hits = WorldSearch.search(query, in: index, players: [], gameNames: names) { _ in .named("") }
            #expect(hits.map { $0.title(in: names) } == ["Bob"] && hits.map { $0.detail(in: names) } == ["Villageois"])
            #expect(hits.first?.position == villager.position)
        }
        #expect(WorldSearch.search("villagers", in: index, players: [], gameNames: names) { _ in .named("") }.isEmpty)
        #expect(WorldSearch.search("creature:villagers", in: index, players: [], gameNames: names) { _ in .named("") }.map { $0.title(in: names) } == ["Bob"])
    }

    @Test func twoWindowsKeepSelectionAndMapLocationsWhenSavedCreatureNamesChange() async throws {
        let game = try game()
        let root = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("minecraft:overworld"))
        func entity(_ id: String, number: Int32, fields: [String: NBT]) -> NBT {
            Fixtures.mob(["id": .string(id), "UUID": .intArray([1, 2, 3, number]), "Health": .float(20),
                "Pos": .list([.double(Double(number) * 5), .double(64), .double(4)])].merging(fields) { $1 })
        }
        let entities = [
            entity("minecraft:sheep", number: 1, fields: ["Color": .byte(0)]),
            entity("minecraft:sheep", number: 2, fields: ["Color": .byte(14)]),
            entity("minecraft:wolf", number: 3, fields: ["CustomName": .string("Berry"), "Owner": .intArray([10, 20, 30, 40])]),
            entity("minecraft:villager", number: 4, fields: [
                "VillagerData": .compound(["profession": .string("minecraft:farmer"), "level": .int(1)]),
            ]),
            entity("minecraft:cat", number: 5, fields: ["Owner": .intArray([10, 20, 30, 40])]),
        ]
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        let chunk = NBT.compound(["DataVersion": .int(Int32(SaveVersion.java26_3)), "Position": .intArray([0, 0]), "Entities": .list(entities)])
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: chunk)]))
            .write(to: dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make(), players = PlayerNames(defaults: TestDefaults.make())
        players.minecraft.choose(game.root)
        let world = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: players,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { world.close() }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        world.savedSearches.add("creature:")
        world.savedSearches.add("creature:fermier")
        for query in world.savedSearches.all { world.savedSearches.setShown(query.id, false) }
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        await world.index.waitForIndex()
        for session in [first, second] {
            await session.search.waitForSearch()
            session.visibility.creatures = [.named, .pet, .villager]
            session.visibility.mobTypes = ["minecraft:sheep"]
        }
        let catalog = first.presentation.selectedIndex.mobTypes
        let farmer = try #require(catalog.specialCreatures.first { $0.creature.id == "minecraft:villager" })
        let cat = try #require(catalog.specialCreatures.first { $0.creature.id == "minecraft:cat" })
        let owner = try #require(cat.creature.owner)
        let linked = first.presentation.linkedPets(to: owner)
        #expect(linked.map { world.gameNames.creature($0.creature) } == ["Berry", "Cat"])
        first.selection.choose(.mobType("minecraft:sheep"))
        second.selection.choose(.creature(farmer.id))
        let original = first.search.matches(for: "creature:").hits
        #expect(original.count == 5 && Set(original.map { $0.title(in: world.gameNames) }) == ["Sheep", "Berry", "Farmer", "Cat"])
        #expect(first.search.matches(for: "creature:fermier").hits.isEmpty)
        let captured = MapContent(session: first)
        let viewport = MapViewport(center: CGPoint(x: 12, y: 4), scale: 8), size = CGSize(width: 800, height: 600)
        let oldLocations = captured.accessibleLocations(viewport: viewport, size: size)
        #expect(Set(oldLocations.map(\.name)) == ["Sheep", "Berry", "Farmer", "Cat"])
        let identity = world.gameNames.identity
        world.names.minecraft.usesGameArtwork = false
        await world.waitForRefresh()
        #expect(world.gameNames.identity == identity)
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            let hits = session.search.matches(for: "creature:").hits
            #expect(hits.map(\.id) == original.map(\.id) && hits.map(\.count) == original.map(\.count))
            #expect(Set(hits.map { $0.title(in: world.gameNames) }) == ["Mouton", "Berry", "Fermier", "Chat"])
            #expect(session.search.matches(for: "creature:fermier").hits.map { $0.title(in: world.gameNames) } == ["Fermier"])
            #expect(session.visibility.mobTypes == ["minecraft:sheep"])
            #expect(session.presentation.selectedIndex.mobTypes.kind("minecraft:sheep")?.count == 2)
            let currentLinks = session.presentation.linkedPets(to: owner)
            #expect(currentLinks.map(\.id) == linked.map(\.id))
            #expect(currentLinks.map { world.gameNames.creature($0.creature) } == ["Berry", "Chat"])
        }
        #expect(first.selection.sidebarSelection == .mobType("minecraft:sheep"))
        #expect(second.selection.sidebarSelection == .creature(farmer.id))
        let current = MapContent(session: first)
        let locations = current.accessibleLocations(viewport: viewport, size: size)
        #expect(Set(locations.map(\.name)) == ["Mouton", "Berry", "Fermier", "Chat"])
        #expect(locations.map(\.id) == oldLocations.map(\.id) && locations.map(\.target) == oldLocations.map(\.target))
        #expect(locations.map(\.position) == oldLocations.map(\.position) && locations.map(\.y) == oldLocations.map(\.y))
        let scene = current.scene(viewport: viewport, size: size)
        #expect(scene.items.map { $0.label.name(in: current.gameNames) } == locations.map(\.name))
        for marker in current.creatures {
            let point = viewport.viewPoint(for: marker.position, in: size)
            #expect(current.hit(at: point, viewport: viewport, size: size)?.target
                == captured.hit(at: point, viewport: viewport, size: size)?.target)
        }
        #expect(captured.gameNames.identity == identity && current.gameNames.identity != identity)
        #expect(captured.accessibleLocations(viewport: viewport, size: size).map(\.name) == oldLocations.map(\.name))
        world.close()
        await world.waitUntilClosed()
        await players.minecraft.waitUntilIdle()
    }
}
