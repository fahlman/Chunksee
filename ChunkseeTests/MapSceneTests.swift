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
        let search = SearchHit(id: "sign", source: .sign, dimension: saved.dimension,
                               position: saved.mapPosition, y: 70, title: "Sign", detail: "Sign", count: 1)
        var content = MapContent()
        content.savedPlaces = [saved]; content.players = [first, second]; content.hits = [search]
        let viewport = MapViewport(center: saved.mapPosition, scale: 32)

        #expect(content.scene(viewport: viewport, size: size).items.map(\.id) ==
                ["player-first", "player-second", "saved-" + saved.id.uuidString])
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
        var content = MapContent()
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
        var content = MapContent(); content.players = [marker]; content.selectedItem = .player(marker.playerID)
        let viewport = MapViewport(center: anchor, scale: 32)
        let item = try #require(content.scene(viewport: viewport, size: size).items.first)
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(item.point == center && item.frame.contains(center))
        #expect(location.frame == item.frame && location.anchor == anchor)
        #expect(location.position == position && hit.position == position)
        #expect(location.y == 48 && hit.y == 48)
        #expect(location.target == hit.target && hit.target == item.target)
        #expect(item.labelPriority == .selected && item.style.opacity == 0.55)
        // A selected sidebar row still wins label collisions after the inspector closes.
        #expect(item.style.lineWidth == 1.5)
        content.selectedPlayerID = marker.playerID
        let highlighted = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(highlighted.style.lineWidth == (kind == .player ? 2.5 : 1.5))
    }
}
