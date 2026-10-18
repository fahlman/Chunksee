import ChunkseeKit
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Chunksee

@Suite struct MarkerGeometryTests {
    private let size = CGSize(width: 440, height: 240)

    private func pet() throws -> CreatureMarker {
        try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: -8.5, y: 63, z: -8.5,
            customName: "Fixture Pet", owner: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            dimension: "minecraft:overworld"))
    }

    private func search() -> SearchHit {
        SearchHit(id: "fixture", source: .sign, dimension: "minecraft:overworld", position: .zero,
                  y: 64, title: "Fixture", detail: "Sign", count: 1)
    }

    private func structure() throws -> StructureMarker {
        let nbt = NBT.compound(["structures": .compound(["starts": .compound([
            "minecraft:village_plains": .compound(["id": .string("minecraft:village_plains"),
                "ChunkX": .int(0), "ChunkZ": .int(0), "Children": .list([.compound([
                    "id": .string("minecraft:jigsaw"), "BB": .intArray([-4, 60, -4, 3, 70, 3]),
                ])]),
            ]),
        ])])])
        return StructureMarker(try #require(StructureStart.starts(inChunk: nbt).first))
    }

    @Test func selectedPetAndSearchBodiesHaveLargerClickTargets() throws {
        let pet = try pet(), hit = search()
        var content = MapContent()
        content.creatures = [pet]
        var viewport = MapViewport(center: pet.position, scale: 2)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let near = CGPoint(x: center.x, y: center.y + 14.5)
        #expect(content.target(at: near, viewport: viewport, size: size) == nil)
        content.selection = .creature(pet)
        #expect(content.target(at: near, viewport: viewport, size: size) == .row(.creature(pet.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
        content.creatures = []; content.selection = nil; content.hits = [hit]
        viewport.center = .zero
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 12.5), viewport: viewport, size: size) == .searchHit(hit.id))
        #expect(content.target(at: near, viewport: viewport, size: size) == nil)
        content.selectedHitID = hit.id
        #expect(content.target(at: near, viewport: viewport, size: size) == .searchHit(hit.id))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 16.01), viewport: viewport, size: size) == nil)
    }

    @Test func largerFixedBadgesGetTheSameClickToleranceWithoutChangingTheirCoordinateSnapshot() throws {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let player = MapMarker(id: "fixture-player", playerID: id, kind: .player,
                               position: CGPoint(x: -20, y: -30), y: 64, label: "Friend", isOutdated: false)
        var content = MapContent()
        content.players = [player]
        var viewport = MapViewport(center: CGPoint(x: -19.5, y: -29.5), scale: 32)
        let hit = content.hit(at: CGPoint(x: center.x + 16.5, y: center.y), viewport: viewport, size: size)
        #expect(hit?.target == .row(.player(id)))
        #expect(hit?.position == player.position && hit?.y == 64)
        #expect(content.target(at: CGPoint(x: center.x + 17.01, y: center.y), viewport: viewport, size: size) == nil)

        let place = SavedPlace(name: "Fixture", dimension: "minecraft:overworld", x: 0, z: 0)
        content.players = []; content.savedPlaces = [place]; viewport.center = .zero
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 13.5), viewport: viewport, size: size) == .row(.savedPlace(place.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.01), viewport: viewport, size: size) == nil)
        let structure = try structure()
        content.savedPlaces = []; content.structures = [structure]
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.5), viewport: viewport, size: size) == .row(.structure(structure.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
    }

    @Test func voiceOverUsesTheDrawnPlayerAnchorForEdgeVisibility() {
        var content = MapContent()
        let viewport = MapViewport(center: .zero, scale: 32)
        // A half-block is 16 points here: the left marker is visible, the right one is outside
        // the existing 20-point accessibility margin once the drawing offset is included.
        content.players = [-25.0, size.width + 15].enumerated().map { index, x in
            MapMarker(id: "edge-\(index)", playerID: UUID(), kind: .player,
                      position: viewport.blockPoint(at: CGPoint(x: x, y: size.height / 2), in: size),
                      y: 64, label: "Edge \(index)", isOutdated: false)
        }
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.map(\.id) == ["player-edge-0"])
        #expect(locations.first?.position == content.players.first?.position)
        #expect(locations.first?.anchor == content.players.first?.anchor)
    }

    @Test func selectedReachCrossesRegionBucketsAndStillChoosesTheClosestMarker() throws {
        let selected = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: 511.999, y: 64, z: 8,
            owner: UUID()), dimension: "minecraft:overworld"))
        var content = MapContent()
        content.creatures = [selected]; content.selection = .creature(selected)
        let viewport = MapViewport(center: selected.position, scale: 32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let edge = CGPoint(x: center.x + 14.99, y: center.y)
        #expect(viewport.blockPoint(at: edge, in: size).x > 512)
        #expect(content.target(at: edge, viewport: viewport, size: size) == .row(.creature(selected.id)))
        let closer = try #require(CreatureMarker(Creature(id: "minecraft:cat", x: 512.2, y: 64, z: 8,
            owner: UUID()), dimension: "minecraft:overworld"))
        content.creatures = [closer, selected]
        #expect(content.target(at: edge, viewport: viewport, size: size) == .row(.creature(closer.id)))
        content.creatures = [selected, closer]
        #expect(content.target(at: edge, viewport: viewport, size: size) == .row(.creature(closer.id)))
    }

    @Test(arguments: [MapMarker.Kind.death, .respawn])
    func playerLocationBadgesRetainTheirOwnBodySize(_ kind: MapMarker.Kind) {
        let marker = MapMarker(id: "location", playerID: UUID(), kind: kind, position: .zero,
                               y: 64, label: "Location", isOutdated: false)
        var content = MapContent(); content.players = [marker]
        let viewport = MapViewport(center: marker.anchor, scale: 32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        #expect(content.target(at: CGPoint(x: center.x + 14.99, y: center.y), viewport: viewport, size: size) == .row(.player(marker.playerID)))
        #expect(content.target(at: CGPoint(x: center.x + 15.01, y: center.y), viewport: viewport, size: size) == nil)
    }

    @Test func unchangedMarkerRenderingProducesComparableImages() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(dimension: dimension, center: .zero)
        defer { map.close() }
        let pet = try pet(), search = search()
        var content = MapContent()
        content.structures = [try structure()]
        content.places = [PlaceMarker(Spawner(x: -40, y: 64, z: 20, mob: "minecraft:zombie")),
            PlaceMarker(NetherPortal(dimension: dimension.id, blocks: [.init(x: -20, y: 64, z: -20)]))]
        content.creatures = [pet]
        content.hits = [search]
        content.players = [MapMarker(id: "player", playerID: UUID(), kind: .player,
            position: CGPoint(x: 30, y: -10), y: 64, label: "Friend", isOutdated: false),
            MapMarker(id: "death", playerID: UUID(), kind: .death,
                position: CGPoint(x: 30, y: 20), y: 64, label: "Death", isOutdated: true),
            MapMarker(id: "respawn", playerID: UUID(), kind: .respawn,
                position: CGPoint(x: -40, y: -30), y: 64, label: "Bed", isOutdated: false)]
        content.places.append(PlaceMarker(PointOfInterest(type: "minecraft:home", x: 70, y: 64, z: -45, freeTickets: 0)))
        content.players.append(MapMarker(id: "outdated", playerID: UUID(), kind: .player,
            position: CGPoint(x: -70, y: -40), y: 64, label: "Old Friend", isOutdated: true))
        content.savedPlaces = [SavedPlace(name: "Fixture", dimension: dimension.id, x: 50, z: 35)]
        for scale in [0.0625, 0.125, 0.25, 0.49, 0.5, 1, 1.99, 2, 4, 32] {
            map.viewport.scale = scale
            for variant in [0, 1, 2] {
                let selected = variant != 0
                content.selection = selected ? .creature(pet) : nil
                content.selectedHitID = selected ? search.id : nil
                content.selectedPlayerID = selected ? (variant == 1 ? content.players.first?.playerID : content.players.last?.playerID) : nil
                let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
                #expect(image.data.count > 1_000)
                let digest = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
                // This bounded baseline/candidate comparison is evidence, not a portable golden
                // image assertion: system symbol/font rasterization can change with macOS.
                print("Marker presentation image \(scale) variant=\(variant): \(digest)")
            }
        }
    }
}
