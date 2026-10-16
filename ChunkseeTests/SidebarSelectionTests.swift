import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import Chunksee

@Suite struct SidebarSelectionTests {
    let playerID = UUID(uuidString: "00000001-0000-0002-0000-000300000004")!
    let missingDimensionPlayerID = UUID(uuidString: "00000005-0000-0006-0000-000700000008")!
    @Test func mapClicksSelectAndRevealRowsWithoutNavigating() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let index = session.selectedIndex
        let structure = try #require(index.structures.first)
        let spawner = try #require(index.places.first { $0.group == .spawner })
        let portal = try #require(index.places.first { $0.group == .portal })
        let creature = try #require(index.creatures.first)
        let biome = try #require(index.biomeAreas.first)
        let place = try #require(session.savedPlaces.add(name: "Base", dimension: "minecraft:overworld", at: CGPoint(x: -35, y: 20)))
        session.visibility.places = [.portal, .spawner]
        session.visibility.biomes = [biome.group]
        let viewport = MapViewport(center: CGPoint(x: 0, y: 0), scale: 8)
        session.map?.viewport = viewport
        var disclosure = SidebarDisclosure()
        disclosure.collapsedLayers = [.structures, .places, .creatures, .biomes]
        let cases: [(CGPoint, SidebarItem)] = [
            (structure.position, .structure(structure.id)), (spawner.position, .place(spawner.id)),
            (portal.position, .place(portal.id)), (creature.position, .creature(creature.id)),
            (place.position, .savedPlace(place.id)),
        ]
        for (position, row) in cases {
            let target = session.mapContent.target(at: viewport.viewPoint(for: position, in: CGSize(width: 800, height: 600)),
                                                   viewport: viewport, size: CGSize(width: 800, height: 600))
            #expect(target == .row(row))
            disclosure.selectOnMap(target, in: session)
            #expect(session.sidebarSelection == row)
            #expect(session.map?.viewport == viewport && !session.navigation.canGoBack)
        }
        // Biomes expose an accessibility location, without an undrawn pointer badge at its center.
        let location = try #require(session.mapContent.accessibleLocations(viewport: viewport, size: CGSize(width: 800, height: 600))
            .first { $0.target == .row(.biome(biome.id)) })
        #expect(session.mapContent.target(at: viewport.viewPoint(for: biome.position, in: CGSize(width: 800, height: 600)),
                                         viewport: viewport, size: CGSize(width: 800, height: 600)) == nil)
        disclosure.selectOnMap(location.target, in: session)
        #expect(disclosure.collapsedLayers.isEmpty)
        #expect(disclosure.structures == [structure.group] && disclosure.places == [.portal, .spawner])
        #expect(disclosure.creatures == [creature.group] && disclosure.biomes == [biome.group])
        // Repeating the same map choice reopens its ancestors after a manual collapse.
        disclosure.collapsedLayers.insert(.places)
        disclosure.places.remove(.spawner)
        disclosure.selectOnMap(.row(.place(spawner.id)), in: session)
        #expect(!disclosure.collapsedLayers.contains(.places) && disclosure.places.contains(.spawner))
        session.sidebarSelection = .worldInfo
        session.choose(.worldInfo)
        session.mapClicked(.row(.place(portal.id)))
        #expect(session.inspector == .selection && session.selection == portal.portal.map(MapSelection.portal))
        #expect(session.sidebarSelection == .place(portal.id) && session.map?.viewport == viewport)
        session.mapClicked(nil)
        #expect(session.sidebarSelection == nil && session.selection == nil && session.inspector == nil)
        session.mapClicked(.row(.place("removed-marker")))
        #expect(session.sidebarSelection == nil)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func aSearchPinSelectsItsCurrentOrSavedResultRow() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "place:spawner"
        await session.search.waitForSearch()
        let hit = try #require(session.search.results.first)
        let viewport = session.map?.viewport
        var disclosure = SidebarDisclosure()
        disclosure.selectOnMap(.searchHit(hit.id), in: session)
        #expect(session.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
        #expect(session.search.selectedHitID == hit.id && session.map?.viewport == viewport)
        session.saveSearch()
        session.search.text = ""
        await session.search.waitForSearch()
        disclosure.selectOnMap(.searchHit(hit.id), in: session)
        let row = SidebarItem.hit(query: "place:spawner", id: hit.id)
        #expect(session.sidebarSelection == row)
        #expect(disclosure.savedSearches == Set(session.savedSearches.all.map(\.id)))
        session.mapClicked(nil)
        #expect(session.search.selectedHitID == nil && session.sidebarSelection == nil)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func mapOverlaySurvivesOtherMarkersAndStaleTargets() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "place:spawner"
        await session.search.waitForSearch()
        let index = session.selectedIndex
        let structure = try #require(index.structures.first), biome = try #require(index.biomeAreas.first)
        let spawner = try #require(index.places.first { $0.group == .spawner })
        let portal = try #require(index.places.first { $0.group == .portal })
        let creature = try #require(index.creatures.first), map = try #require(session.inGameMaps.first { $0.id == 3 })
        let place = try #require(session.savedPlaces.add(name: "Base", dimension: "minecraft:overworld", at: CGPoint(x: -35, y: 20)))
        let hit = try #require(session.search.results.first)
        session.show(map)
        let viewport = session.map?.viewport
        let targets: [MapTarget?] = [.row(.structure(structure.id)), .row(.place(spawner.id)), .row(.biome(biome.id)),
            .row(.savedPlace(place.id)), .searchHit(hit.id), nil,
            .row(.structure("gone")), .row(.place("gone")), .row(.creature("gone")),
            .row(.player(missingDimensionPlayerID)), .searchHit("gone")]
        var disclosure = SidebarDisclosure()
        for target in targets {
            disclosure.selectOnMap(target, in: session)
            #expect(session.mapContent.inGameMap?.map.id == map.id && session.selection == .inGameMap(map))
            #expect(session.inspector == .selection && session.map?.viewport == viewport)
        }
        for target in [MapTarget.row(.place(portal.id)), .row(.creature(creature.id))] {
            session.show(map)
            disclosure.selectOnMap(target, in: session)
            #expect(session.mapContent.inGameMap == nil && session.inspector == .selection)
        }
        // A player has details too, so they replace the map just as a pet does.
        session.show(map)
        disclosure.selectOnMap(.row(.player(playerID)), in: session)
        #expect(session.mapContent.inGameMap == nil && session.inspector == .player(playerID))
        session.close(); await session.waitUntilClosed()
    }

    @Test func emptyMapKeepsWorldInfoAndStorageRowsSelected() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        for row in [SidebarItem.worldInfo, .storage] {
            session.sidebarSelection = row; session.choose(row)
            let inspector = session.inspector
            session.mapClicked(nil)
            #expect(session.sidebarSelection == row && session.inspector == inspector)
        }
        session.close(); await session.waitUntilClosed()
    }

    @Test func mapCannotSelectADisabledPlayerInAMissingDimension() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        let unavailable = try #require(session.listedPlayers.first { $0.uuid == missingDimensionPlayerID })
        #expect(!session.canFocus(unavailable))
        session.mapClicked(.row(.player(unavailable.uuid)))
        #expect(session.sidebarSelection == nil)
        session.close(); await session.waitUntilClosed()
    }

    @Test func selectingAPlayerShowsTheirDetailsAsWithAPet() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let structure = try #require(session.selectedIndex.structures.first)
        let position = try #require(session.listedPlayers.first { $0.uuid == playerID }?.position)
        // Choosing the row centers the map on them and shows their details, highlighted on the map.
        session.sidebarSelection = .player(playerID)
        session.choose(.player(playerID))
        #expect(session.inspector == .player(playerID) && session.mapContent.selectedPlayerID == playerID)
        #expect(session.map?.viewport.center == CGPoint(x: position.x, y: position.z))
        // A marker without details closes them, as it closes a pet's.
        session.mapClicked(.row(.structure(structure.id)))
        #expect(session.inspector == nil && session.mapContent.selectedPlayerID == nil)
        // Their marker shows them again without moving the map; an empty click closes them.
        let viewport = session.map?.viewport
        session.mapClicked(.row(.player(playerID)))
        #expect(session.inspector == .player(playerID) && session.sidebarSelection == .player(playerID))
        #expect(session.map?.viewport == viewport)
        session.mapClicked(nil)
        #expect(session.inspector == nil && session.sidebarSelection == nil)
        // Without a mappable position, their row still shows their details and leaves the map alone.
        let unavailable = try #require(session.listedPlayers.first { $0.uuid == missingDimensionPlayerID })
        #expect(!session.canFocus(unavailable))
        session.sidebarSelection = .player(unavailable.uuid)
        session.choose(.player(unavailable.uuid))
        #expect(session.inspector == .player(unavailable.uuid) && session.map?.viewport == viewport)
        session.close(); await session.waitUntilClosed()
    }

    @Test func hitTestingMatchesVisibleBadgesAndPlayerDrawingCoordinates() throws {
        let size = CGSize(width: 400, height: 300)
        let center = CGPoint(x: 200, y: 150)
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: 0, y: 64, z: 0)]))
        let creature = try #require(CreatureMarker(Creature(id: "minecraft:cat", x: 0.5, y: 64, z: 0.5,
                                                         customName: "Pet", owner: UUID()), dimension: "minecraft:overworld"))
        let bell = PlaceMarker(PointOfInterest(type: "minecraft:meeting", x: 0, y: 64, z: 0, freeTickets: 1))
        var content = MapContent()
        content.places = [portal, bell]
        content.creatures = [creature]
        var viewport = MapViewport(center: portal.position, scale: 1)
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.place(portal.id)))
        content.places = [bell]
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.creature(creature.id)))
        viewport.scale = 0.125
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.place(bell.id)))
        viewport.scale = 0.0625
        #expect(content.target(at: center, viewport: viewport, size: size) == nil)
        content.selection = .creature(creature)
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.creature(creature.id)))
        let playerID = UUID()
        content.players = [.init(id: "player", playerID: playerID, kind: .player, position: CGPoint(x: -10, y: -20),
                                 label: "Friend", isOutdated: false)]
        viewport = MapViewport(center: CGPoint(x: -9.5, y: -19.5), scale: 32)
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.player(playerID)))
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.first { $0.id == "player-player" }?.target == .row(.player(playerID)))
    }

    private func selectionWorld() throws -> URL {
        var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var root = chunk.nbt.compound!
        root["structures"] = .compound(["starts": .compound(["minecraft:village_plains": .compound([
            "id": .string("minecraft:village_plains"), "ChunkX": .int(0), "ChunkZ": .int(0),
            "Children": .list([.compound(["id": .string("minecraft:jigsaw"), "BB": .intArray([-30, 60, -15, -21, 70, -6])])]),
        ])])])
        root["block_entities"] = .list([.compound([
            "id": .string("minecraft:mob_spawner"), "x": .int(3), "y": .int(12), "z": .int(5),
            "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
        ])])
        chunk.nbt = .compound(root)
        let url = try TestWorld.make(chunks: [chunk])
        let dimension = url.appendingPathComponent("dimensions/minecraft/overworld")
        let entity = NBT.compound(["DataVersion": .int(5023), "Position": .intArray([0, 0]), "Entities": .list([.compound([
            "id": .string("minecraft:fox"), "UUID": .intArray([1, 2, 3, 4]), "Health": .float(10),
            "CustomName": .string("Map Fox"), "Pos": .list([.double(13), .double(64), .double(13)]),
        ])])])
        let poi = NBT.compound(["DataVersion": .int(5023), "Sections": .compound(["4": .compound([
            "Valid": .byte(1), "Records": .list([.compound([
                "type": .string("minecraft:nether_portal"), "pos": .intArray([11, 64, 5]), "free_tickets": .int(0),
            ])]),
        ])])])
        for (folder, data) in [("entities", entity), ("poi", poi)] {
            let directory = dimension.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: data)])).write(to: directory.appendingPathComponent("r.0.0.mca"))
        }
        let players = url.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        for (id, dimensionID) in [(playerID, "minecraft:overworld"), (missingDimensionPlayerID, "minecraft:the_nether")] {
            let player = NBT.compound(["DataVersion": .int(5023), "Dimension": .string(dimensionID),
                                      "Pos": .list([.double(-10), .double(64), .double(-20)])])
            try Data(Compression.deflate(player.serialized(), gzip: true)).write(to: players.appendingPathComponent("\(id.uuidString).dat"))
        }
        let maps = url.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let map = InGameMapTests().mapNBT(dimension: .string("minecraft:overworld"))
        try Data(Compression.deflate(map.serialized(), gzip: true)).write(to: maps.appendingPathComponent("3.dat"))
        return url
    }
}
