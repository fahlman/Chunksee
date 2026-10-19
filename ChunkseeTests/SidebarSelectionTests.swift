import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SidebarSelectionTests {
    let playerID = UUID(uuidString: "00000001-0000-0002-0000-000300000004")!
    let missingDimensionPlayerID = UUID(uuidString: "00000005-0000-0006-0000-000700000008")!
    @Test func mapClicksSelectAndRevealRowsWithoutNavigating() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
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
            (place.mapPosition, .savedPlace(place.id)),
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
        let defaults = TestDefaults.make()
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
        #expect(session.selectedHitID == hit.id && session.map?.viewport == viewport)
        session.saveSearch()
        session.search.text = ""
        await session.search.waitForSearch()
        disclosure.selectOnMap(.searchHit(hit.id), in: session)
        let row = SidebarItem.hit(query: "place:spawner", id: hit.id)
        #expect(session.sidebarSelection == row)
        #expect(disclosure.savedSearches == Set(session.savedSearches.all.map(\.id)))
        session.mapClicked(nil)
        #expect(session.selectedHitID == nil && session.sidebarSelection == nil)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func mapOverlaySurvivesOtherMarkersAndStaleTargets() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
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
        let targets: [(MapTarget?, SidebarItem?)] = [
            (.row(.structure(structure.id)), .structure(structure.id)),
            (.row(.place(spawner.id)), .place(spawner.id)), (.row(.biome(biome.id)), .biome(biome.id)),
            (.row(.savedPlace(place.id)), .savedPlace(place.id)),
            (.searchHit(hit.id), .hit(query: "place:spawner", id: hit.id)), (nil, nil),
            (.row(.structure("gone")), nil), (.row(.place("gone")), nil), (.row(.creature("gone")), nil),
            (.row(.player(missingDimensionPlayerID)), nil), (.searchHit("gone"), nil),
        ]
        var disclosure = SidebarDisclosure()
        for (target, row) in targets {
            disclosure.selectOnMap(target, in: session)
            #expect(session.mapContent.inGameMap?.map.id == map.id && session.selection == .inGameMap(map))
            #expect(session.inspector == .selection && session.map?.viewport == viewport)
            #expect(session.sidebarSelection == row)
            #expect(session.selectedHitID == (row == .hit(query: "place:spawner", id: hit.id) ? hit.id : nil))
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        for row in [SidebarItem.worldInfo, .storage] {
            session.choose(row)
            let inspector = session.inspector
            session.mapClicked(nil)
            #expect(session.sidebarSelection == row && session.inspector == inspector)
        }
        session.close(); await session.waitUntilClosed()
    }

    @Test func mapIgnoresPlayerTargetsWithNoMarkerHere() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        // Listed here, since their dimension is missing, but nothing of theirs is drawn here.
        let unavailable = try #require(session.listedPlayers.first { $0.uuid == missingDimensionPlayerID })
        #expect(!session.canFocus(unavailable))
        session.visibility.hiddenPlayers = [playerID]
        for stale in [unavailable.uuid, playerID, UUID()] {
            session.mapClicked(.row(.player(stale)))
            #expect(session.sidebarSelection == nil && session.inspector == nil)
        }
        session.close(); await session.waitUntilClosed()
    }

    @Test func deathAndRespawnMarkersShowTheirPlayerWhereverTheyAreListed() async throws {
        let away = UUID(uuidString: "0000000A-0000-0000-0000-00000000000A")!
        let unplaced = UUID(uuidString: "0000000B-0000-0000-0000-00000000000B")!
        let url = try crossDimensionWorld(away: away, unplaced: unplaced)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        #expect(session.selectedDimensionID == "minecraft:overworld")
        // `away` is listed in the Nether; `unplaced` has no position, so the Overworld lists them.
        #expect(!session.listedPlayers.contains { $0.uuid == away })
        let unplacedPlayer = try #require(session.listedPlayers.first { $0.uuid == unplaced })
        #expect(!session.canFocus(unplacedPlayer))
        let size = CGSize(width: 800, height: 600)
        let viewport = MapViewport(center: .zero, scale: 4)
        session.map?.viewport = viewport
        let markers = session.mapContent.players
        #expect(Set(markers.map(\.playerID)) == [away, unplaced] && markers.allSatisfy { $0.kind != .player })
        let locations = session.mapContent.accessibleLocations(viewport: viewport, size: size)
        var disclosure = SidebarDisclosure()
        for marker in markers {
            let point = viewport.viewPoint(for: CGPoint(x: marker.position.x + 0.5, y: marker.position.y + 0.5), in: size)
            let pointer = session.mapContent.target(at: point, viewport: viewport, size: size)
            let voiceOver = try #require(locations.first { $0.id == "player-" + marker.id }).target
            for target in [pointer, voiceOver] {
                #expect(target == .row(.player(marker.playerID)))
                disclosure.selectOnMap(target, in: session)
                #expect(session.inspector == .player(marker.playerID))
                #expect(session.sidebarSelection == (marker.playerID == unplaced ? .player(unplaced) : nil))
                #expect(session.map?.viewport == viewport)
                session.mapClicked(nil)
                #expect(session.inspector == nil)
            }
        }
        // They replace an in-game map overlay, like a pet.
        let map = try #require(session.inGameMaps.first { $0.id == 3 })
        let death = try #require(markers.first { $0.playerID == away })
        session.show(map, keepingZoom: true)
        disclosure.selectOnMap(.row(.player(death.playerID)), in: session)
        #expect(session.mapContent.inGameMap == nil && session.inspector == .player(away))
        session.close(); await session.waitUntilClosed()
    }

    @Test func selectingAPlayerShowsTheirDetailsAsWithAPet() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        let structure = try #require(session.selectedIndex.structures.first)
        let position = try #require(session.listedPlayers.first { $0.uuid == playerID }?.position)
        // Choosing the row centers the map on them and shows their details, highlighted on the map.
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
        session.choose(.player(unavailable.uuid))
        #expect(session.inspector == .player(unavailable.uuid) && session.map?.viewport == viewport)
        session.close(); await session.waitUntilClosed()
    }

    @Test func sidebarChoicesReplaceOldDetailsAndPinHighlightTogether() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        await session.search.waitForIndex()
        session.search.text = "place:spawner"
        await session.search.waitForSearch()
        let index = session.selectedIndex
        let creature = try #require(index.creatures.first), portal = try #require(index.places.first { $0.portal != nil })
        let spawner = try #require(index.places.first { $0.group == .spawner }), structure = try #require(index.structures.first)
        let biome = try #require(index.biomeAreas.first), hit = try #require(session.search.results.first)
        let saved = try #require(session.savedPlaces.add(name: "Base", dimension: "minecraft:overworld", at: .zero))
        let detailRows: [SidebarItem] = [.creature(creature.id), .place(portal.id), .player(playerID)]
        let plainRows: [SidebarItem] = [.structure(structure.id), .place(spawner.id), .biome(biome.id),
                                        .savedPlace(saved.id), .hit(query: session.search.text, id: hit.id)]
        for detail in detailRows {
            for plain in plainRows {
                session.mapClicked(.searchHit(hit.id))
                session.choose(detail)
                #expect(session.sidebarSelection == detail && session.inspector != nil && session.selectedHitID == nil)
                session.choose(plain)
                #expect(session.sidebarSelection == plain && session.inspector == nil && session.selection == nil)
                #expect(session.mapContent.selectedPlayerID == nil && session.mapContent.selection == nil)
                #expect(session.selectedHitID == (plain == .hit(query: session.search.text, id: hit.id) ? hit.id : nil))
            }
        }
        // A retained overlay is independent of the row and survives every nondetail choice.
        let map = try #require(session.inGameMaps.first)
        for row in plainRows {
            session.show(map, keepingZoom: true)
            session.choose(row)
            #expect(session.sidebarSelection == row && session.selection == .inGameMap(map))
            #expect(session.inspector == .selection && session.mapContent.inGameMap?.map.id == map.id)
        }
        session.show(map, keepingZoom: true)
        session.mapClicked(nil)
        #expect(session.sidebarSelection == .inGameMap(map.id) && session.selection == .inGameMap(map))
        session.mapClicked(.searchHit(hit.id))
        session.mapClicked(nil)
        #expect(session.sidebarSelection == nil && session.selectedHitID == nil && session.selection == .inGameMap(map))
        session.choose(.player(playerID))
        session.inspector = nil
        #expect(session.sidebarSelection == .player(playerID) && session.inspector == nil)
        #expect(session.mapContent.selectedPlayerID == nil && session.selection == nil)
        let missing = try #require(session.savedPlaces.add(name: "Missing", dimension: "missing:dimension", at: .zero))
        let viewport = session.map?.viewport
        #expect(!session.canVisit(missing) && session.listedPlaces.contains { $0.id == missing.id })
        session.choose(.savedPlace(missing.id))
        #expect(session.map?.viewport == viewport && session.sidebarSelection == .player(playerID))
        session.search.text = " diamond "
        #expect(session.canSaveSearch)
        session.saveSearch()
        #expect(session.savedSearches.contains("diamond") && !session.canSaveSearch)
        session.search.text = "diamond "
        #expect(!session.canSaveSearch)
        session.close()
        await session.waitUntilClosed()
    }

    @Test func searchPinsAlwaysHaveAListedRowWithinTheirOwnDimensionsLimit() async throws {
        func spawners() -> TestWorld.ChunkSpec {
            var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
            var nbt = chunk.nbt.compound!
            nbt["block_entities"] = .list((0..<205).map { i in .compound([
                "id": .string("minecraft:mob_spawner"), "x": .int(Int32(i % 16)), "y": .int(12), "z": .int(Int32(i / 16)),
                "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
            ]) })
            chunk.nbt = .compound(nbt)
            return chunk
        }
        let chunk = spawners(), url = try TestWorld.make(chunks: [chunk])
        defer { try? FileManager.default.removeItem(at: url) }
        let nether = url.appendingPathComponent("dimensions/minecraft/the_nether/region")
        try FileManager.default.createDirectory(at: nether, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([chunk])).write(to: nether.appendingPathComponent("r.0.0.mca"))
        let defaults = TestDefaults.make()
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil)
        let sessions = [WorldSession(resources: resources, dimensionID: "minecraft:overworld"),
                        WorldSession(resources: resources, dimensionID: "minecraft:the_nether")]
        defer { sessions.forEach { $0.close() } }
        for session in sessions {
            await session.search.waitForIndex()
            session.search.text = "place:spawner"
            await session.search.waitForSearch()
            let listed = session.listedHits(for: session.search.text)
            #expect(listed.total == 205 && listed.rows.count == 200)
            #expect(session.search.results.count == 410)
            #expect(Set(session.mapContent.hits.map(\.id)) == Set(listed.rows.map(\.id)))
            let viewport = session.map?.viewport
            for hit in session.mapContent.hits {
                session.mapClicked(.searchHit(hit.id))
                #expect(session.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
                #expect(session.selectedHitID == hit.id && session.map?.viewport == viewport)
            }
            let unlisted = try #require(session.listed(session.search.results).dropFirst(200).first)
            session.mapClicked(.searchHit(unlisted.id))
            #expect(session.sidebarSelection == nil && session.selectedHitID == nil)
            session.saveSearch()
            session.search.text = ""
            await session.search.waitForSearch()
            #expect(Set(session.mapContent.hits.map(\.id)) == Set(listed.rows.map(\.id)))
            let hit = try #require(session.mapContent.hits.first)
            session.mapClicked(.searchHit(hit.id))
            #expect(session.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
            // The ordinary Places layer still contains every spawner, independently of search.
            session.visibility.places.insert(.spawner)
            #expect(session.mapContent.places.filter { $0.group == .spawner }.count == 205)
        }
        sessions.forEach { $0.close() }
        for session in sessions { await session.waitUntilClosed() }
    }

    @Test func selectedPortalAndCreatureUseLiveDataAndDisappearWhenRemoved() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        session.refreshDelay = .zero
        await session.search.waitForIndex()
        let portal = try #require(session.selectedIndex.places.first { $0.portal != nil })
        session.choose(.place(portal.id))
        let file = url.appendingPathComponent("dimensions/minecraft/overworld/poi/r.0.0.mca")
        func savePortal(at heights: [Int32]) throws {
            let records: [NBT] = heights.map { .compound([
                "type": .string("minecraft:nether_portal"), "pos": .intArray([11, $0, 5]), "free_tickets": .int(0),
            ]) }
            let nbt = NBT.compound(["DataVersion": .int(5023), "Sections": .compound(["4": .compound([
                "Valid": .byte(1), "Records": .list(records),
            ])])])
            try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: nbt)])).write(to: file)
        }
        try savePortal(at: [64, 65])
        session.worldChanged([file])
        await session.waitForRefresh()
        await session.search.waitForIndex()
        let updated = try #require(session.selectedIndex.places.first { $0.id == portal.id }?.portal)
        #expect(updated != portal.portal)
        #expect(session.selection == .portal(updated))
        #expect(session.sidebarSelection == .place(portal.id) && session.inspector == .selection)
        try savePortal(at: [])
        session.worldChanged([file])
        await session.waitForRefresh()
        await session.search.waitForIndex()
        #expect(session.selection == nil && session.sidebarSelection == nil && session.inspector == nil)
        let creature = try #require(session.selectedIndex.creatures.first)
        session.choose(.creature(creature.id))
        let entities = url.appendingPathComponent("dimensions/minecraft/overworld/entities/r.0.0.mca")
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: .compound([
            "DataVersion": .int(5023), "Entities": .list([]),
        ]))])).write(to: entities)
        session.worldChanged([entities])
        await session.waitForRefresh()
        await session.search.waitForIndex()
        #expect(session.selection == nil && session.sidebarSelection == nil && session.inspector == nil)
        session.close()
        await session.waitUntilClosed()
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
        viewport = MapViewport(center: CGPoint(x: -10, y: -20), scale: 32)
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.player(playerID)))
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.first { $0.id == "player-player" }?.target == .row(.player(playerID)))
    }

    /// An Overworld and a Nether, with `away` now in the Nether but having died and set a respawn
    /// point in the Overworld, and `unplaced` with no current position but both of those.
    private func crossDimensionWorld(away: UUID, unplaced: UUID) throws -> URL {
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/minecraft/the_nether/region"),
                                                withIntermediateDirectories: true)
        func location(_ x: Int32, _ z: Int32) -> NBT {
            .compound(["dimension": .string("minecraft:overworld"), "pos": .intArray([x, 64, z])])
        }
        let players = url.appendingPathComponent("players/data")
        try FileManager.default.createDirectory(at: players, withIntermediateDirectories: true)
        let files: [(UUID, NBT)] = [
            (away, .compound(["DataVersion": .int(5023), "Dimension": .string("minecraft:the_nether"),
                              "Pos": .list([.double(5), .double(70), .double(5)]),
                              "LastDeathLocation": location(20, 20), "respawn": location(-20, -20)])),
            (unplaced, .compound(["DataVersion": .int(5023), "LastDeathLocation": location(30, -30), "respawn": location(-30, 30)])),
        ]
        for (id, player) in files {
            try Data(Compression.deflate(player.serialized(), gzip: true)).write(to: players.appendingPathComponent("\(id.uuidString).dat"))
        }
        let maps = url.appendingPathComponent("data/minecraft/maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let map = InGameMapTests().mapNBT(dimension: .string("minecraft:overworld"))
        try Data(Compression.deflate(map.serialized(), gzip: true)).write(to: maps.appendingPathComponent("3.dat"))
        return url
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
