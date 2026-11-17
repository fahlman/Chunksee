import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct GamePlaceNamesTests {
    private func game() throws -> ItemPictureFixture {
        try ItemPictureFixture(extraFiles: [
            "assets/minecraft/lang/en_us.json": ItemPictureFixture.json([
                "language.code": "en_us",
                "biome.minecraft.plains": "Plains", "biome.minecraft.deep_dark": "Deep Dark",
                "biome.test.grove": "Pack Grove", "biome.test.high.meadow": "High Meadow",
                "block.minecraft.bell": "Bell", "block.minecraft.beehive": "Beehive",
                "block.minecraft.bee_nest": "Bee Nest", "block.minecraft.lodestone": "Lodestone",
                "block.minecraft.lightning_rod": "Lightning Rod", "block.minecraft.nether_portal": "Nether Portal",
                "block.minecraft.chest": "Chest", "entity.minecraft.chest_minecart": "Minecart with Chest",
                "entity.minecraft.zombie": "Zombie", "entity.minecraft.villager.librarian": "Librarian",
                // A structure ID has no translation-key contract; an invented key must not rename it.
                "structure.test.abandoned_camp_old_growth_pine_taiga": "Invented Structure Name",
            ]),
            "assets/minecraft/lang/fr_fr.json": ItemPictureFixture.json([
                "language.code": "fr_fr",
                "biome.minecraft.plains": "Plaines", "biome.minecraft.deep_dark": "Abîmes",
                "biome.test.grove": "Bosquet du pack",
                "block.minecraft.bell": "Cloche", "block.minecraft.beehive": "Ruche",
                "block.minecraft.nether_portal": "Portail du Nether", "block.minecraft.chest": "Coffre",
                "entity.minecraft.chest_minecart": "Wagonnet de coffre",
                "entity.minecraft.zombie": "Revenant", "entity.minecraft.villager.librarian": "Bibliothécaire",
            ]),
        ])
    }

    private func names(_ locale: String) async throws -> GameNames {
        let game = try game()
        defer { game.remove() }
        return GameNames(await (try game.library()).data.language(locale, minecraftDirectory: game.root))
    }

    @Test func biomeNamesUseTheLanguageAndStructuresKeepTheirSavedWordOrder() async throws {
        let names = try await names("fr_FR")
        #expect(names.biome("minecraft:plains") == "Plaines")
        #expect(names.biome("test:grove") == "Bosquet du pack")
        #expect(names.biome("test:high/meadow") == "High Meadow") // Per-key English fallback.
        #expect(names.biome("other:high/meadow") == "High Meadow") // Readable ID fallback.
        #expect(GameNames.unavailable.biome("minecraft:plains") == "Plains")
        let id = "test:abandoned_camp_old_growth_pine_taiga"
        #expect(names.structure(id) == "Abandoned Camp Old Growth Pine Taiga")
        #expect(names.structure(id) == GameNames.unavailable.structure(id))
        #expect(names.biomeDescription(surface: "minecraft:plains", caves: ["minecraft:deep_dark"],
                                      locale: Locale(identifier: "en_US")) == "Plaines · Abîmes below")
        #expect(names.biomeDescription(surface: nil, caves: []) == nil)
        #expect(names.group(StructureGroup.other) == "Other Structures")
        #expect(names.group(PlaceGroup.bed) == "Beds")
        #expect(names.group(CreatureGroup.pet) == "Pets")
    }

    @Test func placesUseTheKnownBlockProfessionAndEntityWithoutGuessingBedColor() async throws {
        let names = try await names("fr_FR")
        func place(_ type: String, claimed: Bool = false) -> PlaceMarker {
            PlaceMarker(PointOfInterest(type: type, x: 0, y: 64, z: 0, freeTickets: claimed ? 0 : 1))
        }
        #expect(place("minecraft:meeting").name(in: names) == "Cloche")
        #expect(place("minecraft:beehive").name(in: names) == "Ruche")
        #expect(place("minecraft:bee_nest").name(in: names) == "Bee Nest")
        #expect(place("minecraft:lodestone").name(in: names) == "Lodestone")
        #expect(place("minecraft:lightning_rod").name(in: names) == "Lightning Rod")
        #expect(place("minecraft:librarian").name(in: names) == "Bibliothécaire’s Workstation")
        #expect(place("minecraft:nether_portal").name(in: names) == "Portail du Nether")
        #expect(place("minecraft:home").name(in: names) == "Bed")
        #expect(place("minecraft:home", claimed: true).name(in: names) == "Villager’s Bed")
        #expect(place("test:future_station").name(in: names) == "Future Station")
        #expect(place("minecraft:meeting").name(in: .unavailable) == "Village Bell")
        let spawner = PlaceMarker(Spawner(x: 1, y: 12, z: 2, mob: "minecraft:zombie"))
        #expect(spawner.name(in: names) == "Revenant Spawner")
        #expect(spawner.name(in: .unavailable) == "Zombie Spawner")
        #expect(PlaceMarker(Spawner(x: 1, y: 12, z: 2, mob: nil)).name(in: names) == "Empty Spawner")
    }

    @Test func lootNamesUseTheSavedTableAndContainerKind() async throws {
        let names = try await names("fr_FR")
        let facts = try TestWorld.facts(blockEntities: [
            .compound(["id": .string("minecraft:chest"), "x": .int(1), "y": .int(20), "z": .int(2),
                       "LootTable": .string("minecraft:chests/simple_dungeon")]),
        ], entities: [
            .compound(["id": .string("minecraft:chest_minecart"), "UUID": .intArray([1, 2, 3, 4]),
                       "Pos": .list([.double(4), .double(20), .double(2)]),
                       "LootTable": .string("example:chests/new_treasure")]),
        ])
        let markers = facts.containers.compactMap { PlaceMarker(unopened: $0) }
        let chest = try #require(markers.first { $0.blockPosition != nil })
        let cart = try #require(markers.first { $0.blockPosition == nil })
        #expect(names.place(chest) == "Simple Dungeon Loot" && names.lootContainer(chest) == "Coffre")
        #expect(names.place(cart) == "Loot: example:chests/new_treasure" && names.lootContainer(cart) == "Wagonnet de coffre")
        #expect(names.lootTable(nil) == "Unopened Loot" && names.lootTable("") == "Unopened Loot")
        #expect(names.lootTable("minecraft:chests/village/village_armorer") == "Village · Village Armorer Loot")
        #expect(chest.lootTable == "minecraft:chests/simple_dungeon" && cart.lootTable == "example:chests/new_treasure")
    }

    @Test func searchesUseTranslatedNamesAndRetainDistinctIDsWithEqualLabels() async throws {
        let names = try await names("fr_FR")
        let spawner = PlaceMarker(Spawner(x: 2, y: 12, z: 3, mob: "minecraft:zombie"))
        let structure = try StructureMarker(StructureTests().start("test:abandoned_camp_old_growth_pine_taiga", chunk: (0, 0)))
        let areas = BiomePresentation.areas(from: [
            ChunkPosition(x: 0, z: 0): "test:high/meadow",
            ChunkPosition(x: 1, z: 0): "other:high/meadow",
            ChunkPosition(x: 2, z: 0): "minecraft:plains",
        ])
        let index = SearchIndex.overworld(DimensionContent(structures: [structure],
            placePoints: PointMarkers([spawner]), biomeAreas: areas))
        func search(_ query: String) -> [SearchHit] {
            WorldSearch.search(query, in: index, players: [], gameNames: names) { _ in .named("") }
        }
        for query in ["place:revenant", "place:minecraft:zombie"] {
            #expect(search(query).map { $0.title(in: names) } == ["Revenant Spawner"])
            #expect(search(query).first?.source == .layer(.place(.spawner), markerID: spawner.id))
        }
        #expect(search("structure:old growth").map { $0.title(in: names) } == ["Abandoned Camp Old Growth Pine Taiga"])
        #expect(search("biome:plaines").map { $0.title(in: names) } == ["Plaines"])
        #expect(search("biome:minecraft:plains").map(\.id) == search("biome:plaines").map(\.id))
        let equal = search("biome:high meadow")
        #expect(equal.count == 2 && Set(equal.map(\.id)).count == 2)
        #expect(equal.map { $0.title(in: names) } == ["High Meadow", "High Meadow"])
        #expect(equal.first?.position != equal.last?.position)
    }

    @Test func twoWindowsRefreshNamesWhileKeepingWorldFactsSelectionAndMapGeometry() async throws {
        let game = try game()
        var firstChunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var fields = try #require(firstChunk.nbt.compound)
        fields["block_entities"] = .list([
            .compound(["id": .string("minecraft:mob_spawner"), "x": .int(3), "y": .int(12), "z": .int(5),
                       "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])])]),
        ])
        fields["structures"] = .compound(["starts": .compound([
            "test:abandoned_camp_old_growth_pine_taiga": .compound([
                "id": .string("test:abandoned_camp_old_growth_pine_taiga"), "ChunkX": .int(0), "ChunkZ": .int(0),
                "Children": .list([.compound(["id": .string("piece"), "BB": .intArray([32, 60, 0, 41, 70, 9])])]),
            ]),
        ])])
        let cave: NBT = .compound(["Y": .byte(-4),
            "block_states": .compound(["palette": .list([.compound(["Name": .string("minecraft:stone")])])]),
            "biomes": .compound(["palette": .list([.string("minecraft:deep_dark")])]),
        ])
        fields["sections"] = .list([cave] + (fields["sections"]?.list ?? []))
        firstChunk.nbt = .compound(fields)
        let root = try TestWorld.make(chunks: [firstChunk])
        defer { game.remove(); try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make(), players = PlayerNames(defaults: TestDefaults.make())
        players.minecraft.choose(game.root)
        let world = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: players,
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { world.close() }
        let first = WorldSession(resources: world), second = WorldSession(resources: world)
        let queries = ["biome:", "biome:plaines", "place:", "place:revenant", "structure:"]
        for query in queries { world.savedSearches.add(query) }
        for query in world.savedSearches.all { world.savedSearches.setShown(query.id, false) }
        world.refreshGameLanguage(preferredLanguage: "en_US")
        await world.waitForRefresh()
        await world.index.waitForIndex()
        let original = first.presentation.selectedIndex
        let structure = try #require(original.structures.first)
        let spawner = try #require(original.places.first)
        let plains = try #require(original.biomeAreas.first { $0.group.id == "minecraft:plains" })
        #expect(original.structures.count == 1 && original.places.count == 1 && original.biomeAreas.count == 2)
        for session in [first, second] {
            await session.search.waitForSearch()
            session.visibility.structures = [.other]
            session.visibility.places = [.spawner]
            session.visibility.biomes = Set(original.biomeAreas.map(\.group))
        }
        first.selection.choose(.place(spawner.id))
        second.selection.choose(.biome(plains.id))
        let oldBiomeHits = first.search.matches(for: "biome:").hits
        let oldPlaceHits = first.search.matches(for: "place:").hits
        #expect(Set(oldBiomeHits.map { $0.title(in: world.gameNames) }) == ["Plains", "Deep Dark"])
        #expect(oldPlaceHits.map { $0.title(in: world.gameNames) } == ["Zombie Spawner"])
        #expect(first.search.matches(for: "biome:plaines").hits.isEmpty && first.search.matches(for: "place:revenant").hits.isEmpty)
        let captured = MapContent(session: first)
        let viewport = MapViewport(center: CGPoint(x: 16, y: 8), scale: 8), size = CGSize(width: 800, height: 600)
        let oldLocations = captured.accessibleLocations(viewport: viewport, size: size)
        #expect(oldLocations.count == 4)
        #expect(captured.biomeDescription(at: CGPoint(x: 2, y: 2)) == "Plains · Deep Dark below")
        let identity = world.gameNames.identity
        world.names.minecraft.usesGameArtwork = false
        await world.waitForRefresh()
        await world.index.waitForIndex()
        #expect(world.gameNames.identity == identity)
        let indexRevision = world.index.revision
        world.refreshGameLanguage(preferredLanguage: "fr_FR")
        await world.waitForRefresh()
        for session in [first, second] {
            await session.search.waitForSearch()
            let biomes = session.search.matches(for: "biome:").hits, places = session.search.matches(for: "place:").hits
            #expect(Set(biomes.map { $0.title(in: world.gameNames) }) == ["Plaines", "Abîmes"])
            #expect(biomes.map(\.id) == oldBiomeHits.map(\.id) && biomes.map(\.count) == oldBiomeHits.map(\.count))
            #expect(places.map { $0.title(in: world.gameNames) } == ["Revenant Spawner"] && places.map(\.id) == oldPlaceHits.map(\.id))
            #expect(session.search.matches(for: "biome:plaines").hits.map { $0.title(in: world.gameNames) } == ["Plaines"])
            #expect(session.search.matches(for: "place:revenant").hits.map { $0.title(in: world.gameNames) } == ["Revenant Spawner"])
            #expect(session.search.matches(for: "structure:").hits.map { $0.title(in: world.gameNames) } == ["Abandoned Camp Old Growth Pine Taiga"])
            #expect(session.presentation.selectedIndex.structures == original.structures)
            #expect(session.presentation.selectedIndex.places == original.places)
            #expect(session.visibility.biomes == Set(original.biomeAreas.map(\.group)))
            #expect(session.visibility.structures == [.other] && session.visibility.places == [.spawner])
        }
        #expect(world.index.revision == indexRevision)
        #expect(first.selection.sidebarSelection == .place(spawner.id) && second.selection.sidebarSelection == .biome(plains.id))
        let current = MapContent(session: first)
        let locations = current.accessibleLocations(viewport: viewport, size: size)
        #expect(Set(locations.map(\.name)) == ["Plaines", "Abîmes", "Revenant Spawner", "Abandoned Camp Old Growth Pine Taiga"])
        #expect(locations.map(\.id) == oldLocations.map(\.id) && locations.map(\.target) == oldLocations.map(\.target))
        #expect(locations.map(\.position) == oldLocations.map(\.position) && locations.map(\.frame) == oldLocations.map(\.frame))
        #expect(current.biomeDescription(at: CGPoint(x: 2, y: 2)) == "Plaines · Abîmes below")
        for point in [spawner.position, structure.position] {
            let point = viewport.viewPoint(for: point, in: size)
            #expect(current.hit(at: point, viewport: viewport, size: size)?.target
                    == captured.hit(at: point, viewport: viewport, size: size)?.target)
        }
        #expect(captured.accessibleLocations(viewport: viewport, size: size).map(\.name) == oldLocations.map(\.name))
        world.close()
        await world.waitUntilClosed()
        await players.minecraft.waitUntilIdle()
    }
}
