import CoreGraphics
import Foundation
import ChunkseeKit
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SidebarSelectionTests {
    let playerID = UUID(uuidString: "00000001-0000-0002-0000-000300000004")!
    let missingDimensionPlayerID = UUID(uuidString: "00000005-0000-0006-0000-000700000008")!

    @Test(.timeLimit(.minutes(1)))
    func selectionObservationReachesTheInspectorAndMapWithoutRetainingItsDocument() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        var session: WorldSession? = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session?.close() }
        await session?.search.waitForIndex()
        let selection = try #require(session?.selection)
        let (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
        defer { continuation.finish() }
        var iterator = updates.makeAsyncIterator()
        let initial = withObservationTracking {
            (session?.selection.inspector, session.map(MapContent.init(session:))?.selectedPlayerID)
        } onChange: {
            continuation.yield(true)
        }
        #expect(initial.0 == nil && initial.1 == nil)
        selection.choose(.player(playerID))
        let changed = await iterator.next(isolation: #isolation)
        #expect(changed == true)
        #expect(selection.inspector == .player(playerID) && session.map(MapContent.init(session:))?.selectedPlayerID == playerID)
        let viewport = session?.map?.viewport
        session?.close()
        await session?.waitUntilClosed()
        selection.choose(.worldInfo)
        #expect(selection.inspector == .player(playerID) && session?.map?.viewport == viewport)
        weak let released = session
        session = nil
        #expect(released == nil)
        selection.choose(.worldInfo)
        #expect(selection.inspector == nil && selection.sidebarSelection == nil && selection.mapSelection == nil)
    }

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
            let target = MapContent(session: session).target(at: viewport.viewPoint(for: position, in: CGSize(width: 800, height: 600)),
                                                   viewport: viewport, size: CGSize(width: 800, height: 600))
            #expect(target == .row(row))
            disclosure.selectOnMap(target, in: session)
            #expect(session.selection.sidebarSelection == row)
            #expect(MapContent(session: session).selectedItem == row)
            #expect(session.map?.viewport == viewport && !session.navigation.canGoBack)
        }
        // Biomes expose an accessibility location, without an undrawn pointer badge at its center.
        let location = try #require(MapContent(session: session).accessibleLocations(viewport: viewport, size: CGSize(width: 800, height: 600))
            .first { $0.target == .row(.biome(biome.id)) })
        #expect(MapContent(session: session).target(at: viewport.viewPoint(for: biome.position, in: CGSize(width: 800, height: 600)),
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
        session.selection.choose(.worldInfo)
        session.selection.mapClicked(.row(.place(portal.id)))
        #expect(session.selection.inspector == .selection && session.selection.mapSelection == portal.portal.map(MapSelection.portal))
        #expect(session.selection.sidebarSelection == .place(portal.id) && session.map?.viewport == viewport)
        session.selection.mapClicked(nil)
        #expect(session.selection.sidebarSelection == nil && session.selection.mapSelection == nil && session.selection.inspector == nil)
        session.selection.mapClicked(.row(.place("removed-marker")))
        #expect(session.selection.sidebarSelection == nil)
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
        #expect(session.selection.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
        #expect(session.selection.selectedHitID == hit.id && session.map?.viewport == viewport)
        session.search.saveSearch()
        session.search.text = ""
        await session.search.waitForSearch()
        disclosure.selectOnMap(.searchHit(hit.id), in: session)
        let row = SidebarItem.hit(query: "place:spawner", id: hit.id)
        #expect(session.selection.sidebarSelection == row)
        #expect(disclosure.savedSearches == Set(session.savedSearches.all.map(\.id)))
        session.selection.mapClicked(nil)
        #expect(session.selection.selectedHitID == nil && session.selection.sidebarSelection == nil)
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
        session.selection.show(map)
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
            #expect(MapContent(session: session).inGameMap?.map.id == map.id && session.selection.mapSelection == .inGameMap(map))
            #expect(session.selection.inspector == .selection && session.map?.viewport == viewport)
            #expect(session.selection.sidebarSelection == row)
            #expect(session.selection.selectedHitID == (row == .hit(query: "place:spawner", id: hit.id) ? hit.id : nil))
        }
        for target in [MapTarget.row(.place(portal.id)), .row(.creature(creature.id))] {
            session.selection.show(map)
            disclosure.selectOnMap(target, in: session)
            #expect(MapContent(session: session).inGameMap == nil && session.selection.inspector == .selection)
        }
        // A player has details too, so they replace the map just as a pet does.
        session.selection.show(map)
        disclosure.selectOnMap(.row(.player(playerID)), in: session)
        #expect(MapContent(session: session).inGameMap == nil && session.selection.inspector == .player(playerID))
        session.close(); await session.waitUntilClosed()
    }

    @Test func emptyMapKeepsWorldInfoAndStorageRowsSelected() async throws {
        let url = try selectionWorld()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        for row in [SidebarItem.worldInfo, .storage] {
            session.selection.choose(row)
            let inspector = session.selection.inspector
            session.selection.mapClicked(nil)
            #expect(session.selection.sidebarSelection == row && session.selection.inspector == inspector)
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
            session.selection.mapClicked(.row(.player(stale)))
            #expect(session.selection.sidebarSelection == nil && session.selection.inspector == nil)
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
        let markers = MapContent(session: session).players
        #expect(Set(markers.map(\.playerID)) == [away, unplaced] && markers.allSatisfy { $0.kind != .player })
        let locations = MapContent(session: session).accessibleLocations(viewport: viewport, size: size)
        var disclosure = SidebarDisclosure()
        for marker in markers {
            let point = viewport.viewPoint(for: CGPoint(x: marker.position.x + 0.5, y: marker.position.y + 0.5), in: size)
            let pointer = MapContent(session: session).target(at: point, viewport: viewport, size: size)
            let voiceOver = try #require(locations.first { $0.id == "player-" + marker.id }).target
            for target in [pointer, voiceOver] {
                #expect(target == .row(.player(marker.playerID)))
                disclosure.selectOnMap(target, in: session)
                #expect(session.selection.inspector == .player(marker.playerID))
                #expect(session.selection.sidebarSelection == (marker.playerID == unplaced ? .player(unplaced) : nil))
                #expect(session.map?.viewport == viewport)
                session.selection.mapClicked(nil)
                #expect(session.selection.inspector == nil)
            }
        }
        // They replace an in-game map overlay, like a pet.
        let map = try #require(session.inGameMaps.first { $0.id == 3 })
        let death = try #require(markers.first { $0.playerID == away })
        session.selection.show(map, keepingZoom: true)
        disclosure.selectOnMap(.row(.player(death.playerID)), in: session)
        #expect(MapContent(session: session).inGameMap == nil && session.selection.inspector == .player(away))
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
        session.selection.choose(.player(playerID))
        #expect(session.selection.inspector == .player(playerID) && MapContent(session: session).selectedPlayerID == playerID)
        #expect(session.map?.viewport.center == CGPoint(x: position.x, y: position.z))
        // A marker without details closes them, as it closes a pet's.
        session.selection.mapClicked(.row(.structure(structure.id)))
        #expect(session.selection.inspector == nil && MapContent(session: session).selectedPlayerID == nil)
        // Their marker shows them again without moving the map; an empty click closes them.
        let viewport = session.map?.viewport
        session.selection.mapClicked(.row(.player(playerID)))
        #expect(session.selection.inspector == .player(playerID) && session.selection.sidebarSelection == .player(playerID))
        #expect(session.map?.viewport == viewport)
        session.selection.mapClicked(nil)
        #expect(session.selection.inspector == nil && session.selection.sidebarSelection == nil)
        // Without a mappable position, their row still shows their details and leaves the map alone.
        let unavailable = try #require(session.listedPlayers.first { $0.uuid == missingDimensionPlayerID })
        #expect(!session.canFocus(unavailable))
        session.selection.choose(.player(unavailable.uuid))
        #expect(session.selection.inspector == .player(unavailable.uuid) && session.map?.viewport == viewport)
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
                session.selection.mapClicked(.searchHit(hit.id))
                session.selection.choose(detail)
                #expect(session.selection.sidebarSelection == detail && session.selection.inspector != nil && session.selection.selectedHitID == nil)
                session.selection.choose(plain)
                #expect(session.selection.sidebarSelection == plain && session.selection.inspector == nil && session.selection.mapSelection == nil)
                #expect(MapContent(session: session).selectedPlayerID == nil && MapContent(session: session).selection == nil)
                #expect(session.selection.selectedHitID == (plain == .hit(query: session.search.text, id: hit.id) ? hit.id : nil))
            }
        }
        // A retained overlay is independent of the row and survives every nondetail choice.
        let map = try #require(session.inGameMaps.first)
        for row in plainRows {
            session.selection.show(map, keepingZoom: true)
            session.selection.choose(row)
            #expect(session.selection.sidebarSelection == row && session.selection.mapSelection == .inGameMap(map))
            #expect(session.selection.inspector == .selection && MapContent(session: session).inGameMap?.map.id == map.id)
        }
        session.selection.show(map, keepingZoom: true)
        session.selection.mapClicked(nil)
        #expect(session.selection.sidebarSelection == .inGameMap(map.id) && session.selection.mapSelection == .inGameMap(map))
        session.selection.mapClicked(.searchHit(hit.id))
        session.selection.mapClicked(nil)
        #expect(session.selection.sidebarSelection == nil && session.selection.selectedHitID == nil && session.selection.mapSelection == .inGameMap(map))
        session.selection.choose(.player(playerID))
        session.selection.inspector = nil
        #expect(session.selection.sidebarSelection == .player(playerID) && session.selection.inspector == nil)
        #expect(MapContent(session: session).selectedPlayerID == nil && session.selection.mapSelection == nil)
        let missing = try #require(session.savedPlaces.add(name: "Missing", dimension: "missing:dimension", at: .zero))
        let viewport = session.map?.viewport
        #expect(!session.annotations.canVisit(missing) && session.annotations.listedPlaces.contains { $0.id == missing.id })
        session.selection.choose(.savedPlace(missing.id))
        #expect(session.map?.viewport == viewport && session.selection.sidebarSelection == .player(playerID))
        session.search.text = " diamond "
        #expect(session.search.canSaveSearch)
        session.search.saveSearch()
        #expect(session.savedSearches.contains("diamond") && !session.search.canSaveSearch)
        session.search.text = "diamond "
        #expect(!session.search.canSaveSearch)
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
            let listed = session.search.listedHits(for: session.search.text, where: session.lists)
            #expect(listed.total == 205 && listed.rows.count == 200)
            #expect(session.search.results.count == 410)
            #expect(Set(MapContent(session: session).hits.map(\.id)) == Set(listed.rows.map(\.id)))
            let viewport = session.map?.viewport
            for hit in MapContent(session: session).hits {
                session.selection.mapClicked(.searchHit(hit.id))
                #expect(session.selection.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
                #expect(session.selection.selectedHitID == hit.id && session.map?.viewport == viewport)
            }
            let unlisted = try #require(session.search.results.filter { session.lists($0.dimension) }.dropFirst(200).first)
            session.selection.mapClicked(.searchHit(unlisted.id))
            #expect(session.selection.sidebarSelection == nil && session.selection.selectedHitID == nil)
            session.search.saveSearch()
            session.search.text = ""
            await session.search.waitForSearch()
            #expect(Set(MapContent(session: session).hits.map(\.id)) == Set(listed.rows.map(\.id)))
            let hit = try #require(MapContent(session: session).hits.first)
            session.selection.mapClicked(.searchHit(hit.id))
            #expect(session.selection.sidebarSelection == .hit(query: "place:spawner", id: hit.id))
            // The ordinary Places layer still contains every spawner, independently of search.
            session.visibility.places.insert(.spawner)
            #expect(MapContent(session: session).places.filter { $0.group == .spawner }.count == 205)
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
        session.selection.choose(.place(portal.id))
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
        #expect(session.selection.mapSelection == .portal(updated))
        #expect(session.selection.sidebarSelection == .place(portal.id) && session.selection.inspector == .selection)
        try savePortal(at: [])
        session.worldChanged([file])
        await session.waitForRefresh()
        await session.search.waitForIndex()
        #expect(session.selection.mapSelection == nil && session.selection.sidebarSelection == nil && session.selection.inspector == nil)
        let creature = try #require(session.selectedIndex.creatures.first)
        session.selection.choose(.creature(creature.id))
        let entities = url.appendingPathComponent("dimensions/minecraft/overworld/entities/r.0.0.mca")
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: .compound([
            "DataVersion": .int(5023), "Entities": .list([]),
        ]))])).write(to: entities)
        session.worldChanged([entities])
        await session.waitForRefresh()
        await session.search.waitForIndex()
        #expect(session.selection.mapSelection == nil && session.selection.sidebarSelection == nil && session.selection.inspector == nil)
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
