import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSceneTests {
    private let size = CGSize(width: 400, height: 200)
    private let center = CGPoint(x: 200, y: 100)

    @Test func overlappingPinsKeepLayerPriorityNearestDistanceAndLaterTies() throws {
        let saved = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: 0, z: 0)
        let first = MapMarker(id: "first", playerID: UUID(), kind: .player, position: saved.mapPosition,
                              y: 48, label: "First", isOutdated: false)
        var second = first
        second.id = "second"; second.playerID = UUID(); second.label = "Second"; second.y = 62
        let search = SearchHit(id: "sign", dimension: saved.dimension,
                               position: saved.mapPosition, y: 70, content: .sign(kind: "minecraft:sign", lines: ["Sign"]))
        var content = MapContent(gameNames: .unavailable)
        content.savedPlaces = [saved]; content.players = [first, second]; content.hits = [search]
        let viewport = MapViewport(center: saved.mapPosition, scale: 32)

        #expect(content.scene(viewport: viewport, size: size).items.map(\.id) ==
                ["search-sign", "player-first", "player-second", "saved-" + saved.id.uuidString])
        let savedHit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(savedHit.target == .row(.savedPlace(saved.id)))
        #expect(savedHit.position == .zero && savedHit.y == nil)

        // A player can be closer, but a saved-place badge above it still wins within its reach.
        content.players[1].position.x += 10 / viewport.scale
        #expect(content.target(at: CGPoint(x: 210, y: 100), viewport: viewport, size: size) == .row(.savedPlace(saved.id)))
        content.savedPlaces = []
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.player(first.playerID)))
        #expect(content.target(at: CGPoint(x: 210, y: 100), viewport: viewport, size: size) == .row(.player(second.playerID)))
        content.players[1].position = first.position
        let playerHit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(playerHit.target == .row(.player(second.playerID)) && playerHit.y == 62)
        content.players.reverse()
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.player(first.playerID)))
        content.players = []
        #expect(content.target(at: center, viewport: viewport, size: size) == .searchHit(search.id))
    }

    @Test func captionsCanEnterBeforePlayerBodiesWithoutAddingOffscreenAccessibleChildren() {
        let viewport = MapViewport(center: .zero, scale: 2)
        var content = MapContent(gameNames: .unavailable)
        content.players = [-61.0, -50, -25, -19, 20].enumerated().map { index, x in
            MapMarker(id: "edge-\(index)", playerID: UUID(), kind: .player,
                      position: viewport.blockPoint(at: CGPoint(x: x, y: 100), in: size),
                      y: 64, label: "Player \(index)", isOutdated: false)
        }
        let scene = content.scene(viewport: viewport, size: size)
        #expect(scene.items.map(\.id) == ["player-edge-1", "player-edge-2", "player-edge-3", "player-edge-4"])
        #expect(content.accessibleLocations(viewport: viewport, size: size).map(\.id) == ["player-edge-3", "player-edge-4"])
        #expect(content.target(at: CGPoint(x: 20, y: 100), viewport: viewport, size: size) == .row(.player(content.players[4].playerID)))
        #expect(content.target(at: CGPoint(x: 2, y: 100), viewport: viewport, size: size) == nil)
    }

    @Test(arguments: [MapMarker.Kind.player, .death, .respawn])
    func playerLocationsCarryTheirOwnHeightAndPhysicalAnchorThroughTheScene(_ kind: MapMarker.Kind) throws {
        let position = kind == .player ? CGPoint(x: -8.7, y: -16.2) : CGPoint(x: -9, y: -17)
        let anchor = kind == .player ? position : CGPoint(x: -8.5, y: -16.5)
        let marker = MapMarker(id: "location", playerID: UUID(), kind: kind,
                               position: position, y: 48, label: "Friend", isOutdated: true)
        var content = MapContent(gameNames: .unavailable); content.players = [marker]; content.selectedItem = .player(marker.playerID)
        let viewport = MapViewport(center: anchor, scale: 32)
        let item = try #require(content.scene(viewport: viewport, size: size).items.first)
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(item.point == center && item.frame.contains(center))
        #expect(location.frame == item.frame && location.anchor == anchor)
        #expect(location.position == position && hit.position == position)
        #expect(location.y == 48 && hit.y == 48)
        #expect(location.target == hit.target && hit.target == item.target)
        #expect(item.labelPriority == .selected && item.isDimmed)
        // Sidebar and inspector selection use the same highlight state.
        content.selectedPlayerID = marker.playerID
        let highlighted = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(highlighted.labelPriority == .selected && highlighted.frame == item.frame)
    }

    @Test func searchPinsShareSelectedGeometryAndSavedCoordinatesWithoutOffscreenTargets() throws {
        let position = CGPoint(x: -8.7, y: -16.2)
        var first = SearchHit(id: "first", dimension: "minecraft:overworld",
                              position: position, y: 48, content: .sign(kind: "minecraft:sign", lines: ["At the mine"]))
        var second = first
        second.id = "second"; second.y = 62
        let viewport = MapViewport(center: position, scale: 2)
        var content = MapContent(gameNames: .unavailable); content.hits = [first, second]; content.selectedHitID = first.id
        let items = content.scene(viewport: viewport, size: size).items
        let selected = try #require(items.first)
        #expect(selected.frame == CGRect(x: 191, y: 91, width: 18, height: 18))
        #expect(selected.frame.contains(center) && selected.point == center && selected.anchor == position)
        #expect(selected.position == position && selected.y == 48)
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.map(\.name) == ["Sign, At the mine", "Sign, At the mine"])
        #expect(locations[0].frame == selected.frame && locations[0].position == position && locations[0].y == 48)
        #expect(content.hit(at: center, viewport: viewport, size: size)?.y == 62)
        content.hits.reverse()
        #expect(content.target(at: center, viewport: viewport, size: size) == selected.target)
        // Selection keeps the same body and picking boundary as its neighbor.
        let outer = CGPoint(x: center.x + 15, y: center.y)
        #expect(content.target(at: outer, viewport: viewport, size: size) == .searchHit(first.id))
        #expect(content.target(at: CGPoint(x: center.x + 15.01, y: center.y), viewport: viewport, size: size) == nil)
        first.position = nil
        second.position = viewport.blockPoint(at: CGPoint(x: -21, y: 100), in: size)
        content.hits = [first, second]
        #expect(content.scene(viewport: viewport, size: size).items.isEmpty)
        #expect(content.accessibleLocations(viewport: viewport, size: size).isEmpty)
        #expect(content.target(at: CGPoint(x: -21, y: 100), viewport: viewport, size: size) == nil)
    }

    @Test func placesAndCreaturesSharePhysicalCoordinatesAndSelectedFrames() throws {
        let spawner = PlaceMarker(Spawner(x: -9, y: 48, z: -17, mob: "minecraft:zombie"))
        let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: -8.7, y: 62.25, z: -16.2,
            customName: "Summer", owner: UUID()), dimension: "minecraft:overworld"))
        var content = MapContent(gameNames: .unavailable)
        for showPet in [false, true] {
            content.places = showPet ? [] : [spawner]
            content.creatures = showPet ? [pet] : []
            content.selection = showPet ? .creature(pet) : nil
            let position = showPet ? pet.position : spawner.position
            let viewport = MapViewport(center: position, scale: 32)
            let item = try #require(content.scene(viewport: viewport, size: size).items.first)
            let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
            let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
            #expect(item.point == center && item.frame.contains(center))
            #expect(item.frame.width == 32)
            #expect(location.frame == item.frame && location.anchor == position)
            #expect(location.position == position && hit.position == position)
            #expect(location.y == (showPet ? 62.25 : 48) && hit.y == location.y)
            #expect(location.target == hit.target && hit.target == item.target)
            #expect(location.name == (showPet ? "Summer" : "Zombie Spawner"))
            #expect(item.labelPriority == (showPet ? .selected : .other))
        }
    }

    @Test func portalPriorityKeepsCreatureDrawingAndBiomeAccessibilityOrder() throws {
        let portal = NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: 0, y: 64, z: 0)])
        let place = PlaceMarker(portal)
        let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: place.position.x, y: 64,
            z: place.position.y, owner: UUID()), dimension: portal.dimension))
        var content = MapContent(gameNames: .unavailable)
        content.places = [place]; content.creatures = [pet]; content.selection = .portal(portal)
        content.biomeAreas = BiomePresentation.areas(from: [.init(x: 0, z: 0): "minecraft:plains"])
        let hit = SearchHit(id: "pin", dimension: portal.dimension,
            position: place.position, y: 70, content: .sign(kind: "minecraft:sign", lines: ["Overlapping"]))
        content.hits = [hit]
        let viewport = MapViewport(center: place.position, scale: 2)
        let scene = content.scene(viewport: viewport, size: size)
        #expect(scene.items.map(\.target) == [.row(.place(place.id)), .row(.creature(pet.id)), .searchHit(hit.id)])
        #expect(scene.items.first?.labelPriority == .selected)
        #expect(content.accessibleLocations(viewport: viewport, size: size).map(\.target) == [
            .row(.place(place.id)), .row(.creature(pet.id)), .row(.biome(content.biomeAreas[0].id)), .searchHit(hit.id),
        ])
        #expect(content.target(at: center, viewport: viewport, size: size) == .searchHit(hit.id))
        content.hits = []
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.place(place.id)))
        content.places = []
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.creature(pet.id)))
        content.creatures = []
        let biomePoint = viewport.viewPoint(for: content.biomeAreas[0].position, in: size)
        #expect(content.target(at: biomePoint, viewport: viewport, size: size) == nil)
    }

}
