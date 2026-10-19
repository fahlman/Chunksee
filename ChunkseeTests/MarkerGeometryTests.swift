import ChunkseeKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MarkerGeometryTests {
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
        var viewport = MapViewport(center: player.position, scale: 32)
        let hit = content.hit(at: CGPoint(x: center.x + 16.5, y: center.y), viewport: viewport, size: size)
        #expect(hit?.target == .row(.player(id)))
        #expect(hit?.position == player.position && hit?.y == 64)
        #expect(content.target(at: CGPoint(x: center.x + 17.01, y: center.y), viewport: viewport, size: size) == nil)

        let place = SavedPlace(name: "Fixture", dimension: "minecraft:overworld", x: 0, z: 0)
        content.players = []; content.savedPlaces = [place]; viewport.center = place.mapPosition
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 13.5), viewport: viewport, size: size) == .row(.savedPlace(place.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.01), viewport: viewport, size: size) == nil)
        let structure = try structure()
        content.savedPlaces = []; content.structures = [structure]; viewport.center = structure.position
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.5), viewport: viewport, size: size) == .row(.structure(structure.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
    }

    @Test func voiceOverUsesTheDrawnPlayerAnchorForEdgeVisibility() {
        var content = MapContent()
        let viewport = MapViewport(center: .zero, scale: 32)
        // Live entities have no half-block adjustment: the left marker is outside the existing
        // 20-point accessibility margin, while the right marker is inside it.
        content.players = [-25.0, size.width + 15].enumerated().map { index, x in
            MapMarker(id: "edge-\(index)", playerID: UUID(), kind: .player,
                      position: viewport.blockPoint(at: CGPoint(x: x, y: size.height / 2), in: size),
                      y: 64, label: "Edge \(index)", isOutdated: false)
        }
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.map(\.id) == ["player-edge-1"])
        #expect(locations.first?.position == content.players.last?.position)
        #expect(locations.first?.anchor == content.players.last?.anchor)
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

    @Test(arguments: [MapMarker.Kind.player, .death, .respawn])
    func entityAndBlockLocationsUseTheirPhysicalAnchors(_ kind: MapMarker.Kind) throws {
        let position = kind == .player ? CGPoint(x: -8.7, y: -16.2) : CGPoint(x: -9, y: -17)
        let expected = kind == .player ? position : CGPoint(x: -8.5, y: -16.5)
        let marker = MapMarker(id: "negative-location", playerID: UUID(), kind: kind,
                               position: position, y: 64, label: "Friend", isOutdated: false)
        var content = MapContent(); content.players = [marker]
        let viewport = MapViewport(center: expected, scale: 32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(hit.target == .row(.player(marker.playerID)))
        #expect(hit.position == position && hit.y == 64)
        let accessible = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        #expect(accessible.anchor == expected && accessible.position == position)
        #expect(marker.anchor == expected)
    }

    @Test(arguments: [0.25, 2.0, 32.0])
    func accessibilityFramesFollowDrawnBodiesWhenPannedAndZoomed(_ scale: Double) throws {
        let pet = try pet(), search = search(), structure = try structure()
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: -2, y: 64, z: 1)]))
        let spawner = PlaceMarker(Spawner(x: 2, y: 64, z: -1, mob: "minecraft:zombie"))
        let saved = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: 1, z: 2)
        let players = [MapMarker.Kind.player, .death, .respawn].enumerated().map { i, kind in
            MapMarker(id: "frame-\(i)", playerID: UUID(), kind: kind, position: CGPoint(x: i - 1, y: -2),
                      y: 64, label: "Friend", isOutdated: false)
        }
        var content = MapContent()
        content.structures = [structure]; content.places = [portal, spawner]
        content.creatures = [pet]; content.hits = [search]; content.players = players; content.savedPlaces = [saved]
        let viewport = MapViewport(center: CGPoint(x: -1, y: 1), scale: scale)
        for selected in [false, true] {
            content.selection = selected ? .creature(pet) : nil
            content.selectedHitID = selected ? search.id : nil
            let expected: [(String, CGPoint, CGFloat)] = [
                ("structure-" + structure.id, structure.position, 9),
                ("place-" + portal.id, portal.position, 8),
                ("place-" + spawner.id, spawner.position, 6),
                ("creature-" + pet.id, pet.position, selected ? 9 : 6),
                ("search-" + search.id, search.position!, selected ? 10 : 7),
                ("saved-" + saved.id.uuidString, saved.mapPosition, 8),
            ] + players.map { ("player-" + $0.id, $0.anchor, $0.kind == .player ? 11 : 9) }
            let locations = content.accessibleLocations(viewport: viewport, size: size)
            for (id, anchor, radius) in expected {
                let point = viewport.viewPoint(for: anchor, in: size)
                guard CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20).contains(point) else { continue }
                let frame = try #require(locations.first { $0.id == id }?.frame)
                #expect(frame.contains(point))
                #expect(frame.midX == point.x && frame.midY == point.y)
                #expect(frame.width == radius * 2 && frame.height == radius * 2)
            }
        }
    }

    @Test func biomeAccessibilityFrameEnclosesTheDrawnArea() throws {
        let bounds = CGRect(x: -32, y: -16, width: 64, height: 32)
        let area = BiomeArea(id: "plains", group: BiomeGroup(id: "minecraft:plains"), chunkCount: 8,
                             position: CGPoint(x: -8, y: 8), bounds: bounds, chunks: Path(bounds), outline: Path(bounds))
        var content = MapContent(); content.biomeAreas = [area]
        let viewport = MapViewport(center: CGPoint(x: 5, y: -10), scale: 2)
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        #expect(location.frame.origin == viewport.viewPoint(for: bounds.origin, in: size))
        #expect(location.frame.size == CGSize(width: 128, height: 64))
        #expect(location.frame.contains(viewport.viewPoint(for: area.position, in: size)))
    }

    @Test func accessibilityFramesRespectLayerAndZoomVisibility() throws {
        let pet = try pet()
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: 0, y: 64, z: 0)]))
        let spawner = PlaceMarker(Spawner(x: 0, y: 64, z: 0, mob: "minecraft:zombie"))
        var content = MapContent(); content.creatures = [pet]; content.places = [portal, spawner]
        let viewport = MapViewport(center: .zero, scale: 0.0625)
        #expect(content.accessibleLocations(viewport: viewport, size: size).map(\.id) == ["place-" + portal.id])
        content.selection = .creature(pet)
        #expect(content.accessibleLocations(viewport: viewport, size: size).contains { $0.id == "creature-" + pet.id })
        content.shownCreatureGroups = []; content.shownPlaceGroups = []
        #expect(content.accessibleLocations(viewport: viewport, size: size).isEmpty)
    }

    @Test func markerRenderingProducesComparableImages() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero)
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
                let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
                let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                Attachment.record(pixels, named: "markers-\(scale)-\(variant).png", as: .png)
            }
        }
    }

    @Test func captionsFormatNamesOnlyWhenTheyAreShown() throws {
        let probe = NameProbe()
        let cases: [(MarkerStyle, CGFloat, Bool)] = [
            (.place(.spawner, claimed: false), 1, false),
            (.structure(try structure().group), 0.49, false),
            (.player(.death, outdated: true, selected: false), 4, false),
            (.search(selected: true), 4, false),
            (.place(.spawner, claimed: false), 2, true),
            (.creature(try pet().group, selected: true), 0.0625, true),
            (.player(.player, outdated: true, selected: true), 0.0625, true),
        ]
        for (style, scale, expected) in cases {
            let before = probe.calls
            let renderer = ImageRenderer(content: Canvas { context, _ in
                style.label(probe.name(), id: "fixture", priority: .other,
                            at: CGPoint(x: 120, y: 30), scale: scale, in: context)?.draw(in: context)
            }.frame(width: 240, height: 100))
            _ = try #require(renderer.cgImage)
            #expect((probe.calls > before) == expected)
        }
    }

    private final class NameProbe {
        var calls = 0
        func name() -> String { calls += 1; return "Fixture label" }
    }
}
