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
        SearchHit(id: "fixture", dimension: "minecraft:overworld", position: .zero,
                  y: 64, content: .sign(kind: "test:fixture", lines: ["Sign"]))
    }

    private func structure() throws -> StructureMarker {
        try StructureMarker(StructureTests().start("minecraft:village_plains", chunk: (0, 0),
            pieces: [("minecraft:jigsaw", [-4, 60, -4, 3, 70, 3])]))
    }

    @Test func badgesKeepOneSizeWhenSelectedThenGrowWithTheBlockUpToTheCap() throws {
        let pet = try pet()
        var content = MapContent(gameNames: .unavailable); content.creatures = [pet]
        let cases: [(scale: CGFloat, diameter: CGFloat)] = [
            (2, 18), (12, 18), (16, 18), (18, 18), (22, 22), (32, 32), (64, 32),
        ]
        for sample in cases {
            let viewport = MapViewport(center: pet.position, scale: sample.scale)
            for selected in [false, true] {
                content.highlighted = selected ? [.row(.creature(pet.id))] : []
                let item = try #require(content.scene(viewport: viewport, size: size).items.first)
                let diameter = sample.diameter
                #expect(item.frame.size == CGSize(width: diameter, height: diameter))
                #expect(item.frame.midX == size.width / 2 && item.frame.midY == size.height / 2)
                #expect(item.anchor == pet.position && item.position == pet.position && item.y == 63)
            }
        }
    }

    @Test(arguments: [CGFloat(2), 16, 18, 24, 32])
    func everyMarkerKindSharesOneBodyAndPickingBoundaryAtEachZoom(_ scale: CGFloat) throws {
        let pet = try pet(), search = search(), structure = try structure()
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: -2, y: 64, z: 1)]))
        let spawner = PlaceMarker(Spawner(x: 2, y: 64, z: -1, mob: "minecraft:zombie"))
        let saved = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: 1, z: 2)
        var cases: [(MapContent, CGPoint, MapTarget)] = []
        var content = MapContent(gameNames: .unavailable); content.structures = [structure]
        cases.append((content, structure.position, .row(.structure(structure.id))))
        for place in [portal, spawner] {
            content = MapContent(gameNames: .unavailable); content.places = [place]
            cases.append((content, place.position, .row(.place(place.id))))
        }
        content = MapContent(gameNames: .unavailable); content.creatures = [pet]
        cases.append((content, pet.position, .row(.creature(pet.id))))
        content = MapContent(gameNames: .unavailable); content.hits = [search]
        cases.append((content, try #require(search.position), .searchHit(search.id)))
        content = MapContent(gameNames: .unavailable); content.savedPlaces = [saved]
        cases.append((content, saved.mapPosition, .row(.savedPlace(saved.id))))
        for kind in [MapMarker.Kind.player, .death, .respawn] {
            let marker = MapMarker(id: "grown-\(kind)", playerID: UUID(), kind: kind,
                position: CGPoint(x: -8.7, y: -16.2), y: 48, name: .named("Friend"), isOutdated: false)
            content = MapContent(gameNames: .unavailable); content.players = [marker]
            cases.append((content, marker.anchor, .row(.player(marker.playerID))))
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for (content, anchor, target) in cases {
            let viewport = MapViewport(center: anchor, scale: scale)
            let diameter: CGFloat = scale <= 18 ? 18 : scale
            let radius = diameter / 2
            let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
            #expect(location.frame.size == CGSize(width: diameter, height: diameter))
            // Projecting fractional negative coordinates can shift the center by one ULP.
            #expect(abs(location.frame.midX - center.x) < 0.000001 && abs(location.frame.midY - center.y) < 0.000001)
            let hit = try #require(content.hit(at: CGPoint(x: center.x + radius + 5.999, y: center.y), viewport: viewport, size: size))
            #expect(hit.target == target && hit.position == location.position && hit.y == location.y)
            #expect(content.target(at: CGPoint(x: center.x + radius + 6.01, y: center.y), viewport: viewport, size: size) == nil)
        }
    }

    @Test func closeZoomDoesNotPickPointBadgesOutsideTheDrawingMargin() throws {
        let viewport = MapViewport(center: .zero, scale: 32)
        let position = viewport.blockPoint(at: CGPoint(x: -21, y: size.height / 2), in: size)
        let pet = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: position.x, y: 64, z: position.y,
            owner: UUID()), dimension: "minecraft:overworld"))
        var content = MapContent(gameNames: .unavailable); content.creatures = [pet]
        #expect(content.scene(viewport: viewport, size: size).items.isEmpty)
        #expect(content.accessibleLocations(viewport: viewport, size: size).isEmpty)
        #expect(content.target(at: CGPoint(x: 0, y: size.height / 2), viewport: viewport, size: size) == nil)
    }

    @Test func selectionHighlightsPetAndSearchBodiesWithoutChangingTheirSizeOrClickTargets() throws {
        let pet = try pet(), hit = search()
        var content = MapContent(gameNames: .unavailable)
        content.creatures = [pet]
        var viewport = MapViewport(center: pet.position, scale: 2)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let near = CGPoint(x: center.x, y: center.y + 14.5)
        let ordinary = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(content.target(at: near, viewport: viewport, size: size) == .row(.creature(pet.id)))
        content.highlighted = [.row(.creature(pet.id))]
        let selected = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(ordinary.frame == selected.frame && ordinary.labelPriority != .selected && selected.labelPriority == .selected)
        #expect(content.target(at: near, viewport: viewport, size: size) == .row(.creature(pet.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
        content.creatures = []; content.highlighted = []; content.hits = [hit]
        viewport.center = .zero
        let pin = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(content.target(at: near, viewport: viewport, size: size) == .searchHit(hit.id))
        content.highlighted = [.searchHit(hit.id)]
        let selectedPin = try #require(content.scene(viewport: viewport, size: size).items.first)
        #expect(pin.frame == selectedPin.frame && pin.labelPriority != .selected && selectedPin.labelPriority == .selected)
        #expect(content.target(at: near, viewport: viewport, size: size) == .searchHit(hit.id))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
    }

    @Test func commonSizedBadgesKeepTheirCoordinateSnapshot() throws {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let player = MapMarker(id: "fixture-player", playerID: id, kind: .player,
                               position: CGPoint(x: -20, y: -30), y: 64, name: .named("Friend"), isOutdated: false)
        var content = MapContent(gameNames: .unavailable)
        content.players = [player]
        var viewport = MapViewport(center: player.position, scale: 2)
        let hit = content.hit(at: CGPoint(x: center.x + 14.5, y: center.y), viewport: viewport, size: size)
        #expect(hit?.target == .row(.player(id)))
        #expect(hit?.position == player.position && hit?.y == 64)
        #expect(content.target(at: CGPoint(x: center.x + 15.01, y: center.y), viewport: viewport, size: size) == nil)

        let place = SavedPlace(name: "Fixture", dimension: "minecraft:overworld", x: 0, z: 0)
        content.players = []; content.savedPlaces = [place]; viewport.center = place.mapPosition
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.5), viewport: viewport, size: size) == .row(.savedPlace(place.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
        let structure = try structure()
        content.savedPlaces = []; content.structures = [structure]; viewport.center = structure.position
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 14.5), viewport: viewport, size: size) == .row(.structure(structure.id)))
        #expect(content.target(at: CGPoint(x: center.x, y: center.y + 15.01), viewport: viewport, size: size) == nil)
    }

    @Test func voiceOverUsesTheDrawnPlayerAnchorForEdgeVisibility() {
        var content = MapContent(gameNames: .unavailable)
        let viewport = MapViewport(center: .zero, scale: 32)
        // Live entities have no half-block adjustment: the left marker is outside the existing
        // 20-point accessibility margin, while the right marker is inside it.
        content.players = [-25.0, size.width + 15].enumerated().map { index, x in
            MapMarker(id: "edge-\(index)", playerID: UUID(), kind: .player,
                      position: viewport.blockPoint(at: CGPoint(x: x, y: size.height / 2), in: size),
                      y: 64, name: .named("Edge \(index)"), isOutdated: false)
        }
        let locations = content.accessibleLocations(viewport: viewport, size: size)
        #expect(locations.map(\.id) == ["player-edge-1"])
        #expect(locations.first?.position == content.players.last?.position)
        #expect(locations.first?.anchor == content.players.last?.anchor)
    }

    @Test func selectedReachCrossesRegionBucketsAndStillChoosesTheClosestMarker() throws {
        let selected = try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: 511.999, y: 64, z: 8,
            owner: UUID()), dimension: "minecraft:overworld"))
        var content = MapContent(gameNames: .unavailable)
        content.creatures = [selected]; content.highlighted = [.row(.creature(selected.id))]
        let viewport = MapViewport(center: selected.position, scale: 32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let edge = CGPoint(x: center.x + 21.99, y: center.y)
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
    func playerLocationBadgesShareTheCommonBodySize(_ kind: MapMarker.Kind) {
        let marker = MapMarker(id: "location", playerID: UUID(), kind: kind, position: .zero,
                               y: 64, name: .named("Location"), isOutdated: false)
        var content = MapContent(gameNames: .unavailable); content.players = [marker]
        let viewport = MapViewport(center: marker.anchor, scale: 2)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        #expect(content.target(at: CGPoint(x: center.x + 14.99, y: center.y), viewport: viewport, size: size) == .row(.player(marker.playerID)))
        #expect(content.target(at: CGPoint(x: center.x + 15.01, y: center.y), viewport: viewport, size: size) == nil)
    }

    @Test(arguments: [MapMarker.Kind.player, .death, .respawn])
    func entityAndBlockLocationsUseTheirPhysicalAnchors(_ kind: MapMarker.Kind) throws {
        let position = kind == .player ? CGPoint(x: -8.7, y: -16.2) : CGPoint(x: -9, y: -17)
        let expected = kind == .player ? position : CGPoint(x: -8.5, y: -16.5)
        let marker = MapMarker(id: "negative-location", playerID: UUID(), kind: kind,
                               position: position, y: 64, name: .named("Friend"), isOutdated: false)
        var content = MapContent(gameNames: .unavailable); content.players = [marker]
        let viewport = MapViewport(center: expected, scale: 32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(hit.target == .row(.player(marker.playerID)))
        #expect(hit.position == position && hit.y == 64)
        let accessible = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        #expect(accessible.anchor == expected && accessible.position == position)
        #expect(marker.anchor == expected)
    }

    @Test(arguments: [0.25, 2.0, 16.0, 18.0, 24.0, 32.0])
    func accessibilityFramesFollowDrawnBodiesWhenPannedAndZoomed(_ scale: Double) throws {
        let pet = try pet(), search = search(), structure = try structure()
        let portal = PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [.init(x: -2, y: 64, z: 1)]))
        let spawner = PlaceMarker(Spawner(x: 2, y: 64, z: -1, mob: "minecraft:zombie"))
        let saved = SavedPlace(name: "Home", dimension: "minecraft:overworld", x: 1, z: 2)
        let players = [MapMarker.Kind.player, .death, .respawn].enumerated().map { i, kind in
            MapMarker(id: "frame-\(i)", playerID: UUID(), kind: kind, position: CGPoint(x: i - 1, y: -2),
                      y: 64, name: .named("Friend"), isOutdated: false)
        }
        var content = MapContent(gameNames: .unavailable)
        content.structures = [structure]; content.places = [portal, spawner]
        content.creatures = [pet]; content.hits = [search]; content.players = players; content.savedPlaces = [saved]
        let viewport = MapViewport(center: CGPoint(x: -1, y: 1), scale: scale)
        for selected in [false, true] {
            content.highlighted = selected ? [.row(.creature(pet.id)), .searchHit(search.id)] : []
            let expected: [(String, CGPoint, CGFloat)] = [
                ("structure-" + structure.id, structure.position, 9),
                ("place-" + portal.id, portal.position, 9),
                ("place-" + spawner.id, spawner.position, 9),
                ("creature-" + pet.id, pet.position, 9),
                ("search-" + search.id, search.position!, 9),
                ("saved-" + saved.id.uuidString, saved.mapPosition, 9),
            ] + players.map { ("player-" + $0.id, $0.anchor, 9) }
            let locations = content.accessibleLocations(viewport: viewport, size: size)
            for (id, anchor, radius) in expected {
                let point = viewport.viewPoint(for: anchor, in: size)
                guard CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20).contains(point) else { continue }
                let frame = try #require(locations.first { $0.id == id }?.frame)
                #expect(frame.contains(point))
                #expect(frame.midX == point.x && frame.midY == point.y)
                let diameter = scale > 18 ? scale : radius * 2
                #expect(frame.width == diameter && frame.height == diameter)
            }
        }
    }

    @Test func biomeAccessibilityFrameEnclosesTheDrawnArea() throws {
        let bounds = CGRect(x: -32, y: -16, width: 64, height: 32)
        let area = BiomeArea(id: "plains", group: BiomeGroup(id: "minecraft:plains"), chunkCount: 8,
                             position: CGPoint(x: -8, y: 8), bounds: bounds, chunks: Path(bounds), outline: Path(bounds))
        var content = MapContent(gameNames: .unavailable); content.biomeAreas = [area]
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
        var content = MapContent(gameNames: .unavailable); content.creatures = [pet]; content.places = [portal, spawner]
        let viewport = MapViewport(center: .zero, scale: 0.0625)
        #expect(content.accessibleLocations(viewport: viewport, size: size).map(\.id) == ["place-" + portal.id])
        content.highlighted = [.row(.creature(pet.id))]
        #expect(content.accessibleLocations(viewport: viewport, size: size).contains { $0.id == "creature-" + pet.id })
        content.shownCreatureGroups = []; content.shownPlaceGroups = []
        #expect(content.accessibleLocations(viewport: viewport, size: size).isEmpty)
    }

    @Test func markerRenderingProducesComparableImages() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(definitions: { .unknown }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), world: .init(try World(contentsOf: url)), dimension: dimension, center: .zero)
        defer { map.close() }
        let pet = try pet(), search = search()
        var content = MapContent(gameNames: .unavailable)
        content.structures = [try structure()]
        content.places = [PlaceMarker(Spawner(x: -40, y: 64, z: 20, mob: "minecraft:zombie")),
            PlaceMarker(NetherPortal(dimension: dimension.id, blocks: [.init(x: -20, y: 64, z: -20)]))]
        content.creatures = [pet]
        content.hits = [search]
        content.players = [MapMarker(id: "player", playerID: UUID(), kind: .player,
            position: CGPoint(x: 30, y: -10), y: 64, name: .named("Friend"), isOutdated: false),
            MapMarker(id: "death", playerID: UUID(), kind: .death,
                position: CGPoint(x: 30, y: 20), y: 64, name: .named("Friend"), isOutdated: true),
            MapMarker(id: "respawn", playerID: UUID(), kind: .respawn,
                position: CGPoint(x: -40, y: -30), y: 64, name: .named("Friend"), isOutdated: false)]
        content.places.append(PlaceMarker(PointOfInterest(type: "minecraft:home", x: 70, y: 64, z: -45, freeTickets: 0)))
        content.players.append(MapMarker(id: "outdated", playerID: UUID(), kind: .player,
            position: CGPoint(x: -70, y: -40), y: 64, name: .named("Old Friend"), isOutdated: true))
        content.savedPlaces = [SavedPlace(name: "Fixture", dimension: dimension.id, x: 50, z: 35)]
        for scale in [0.0625, 0.125, 0.25, 0.49, 0.5, 1, 1.99, 2, 4, 32] {
            map.viewport.scale = scale
            for variant in [0, 1, 2] {
                let selected = variant != 0
                content.highlighted = selected ? [.row(.creature(pet.id)), .searchHit(search.id)] : []
                if selected, let player = variant == 1 ? content.players.first : content.players.last {
                    content.highlighted.insert(.row(.player(player.playerID)))
                }
                let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2, colorScheme: .light, locale: Locale(identifier: "en_US")))
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
        let styles: [MarkerStyle] = [.place(.spawner), .structure(try structure().group),
                                    .player(.death), .search, .creature(try pet().group), .savedPlace]
        for style in styles {
            for (scale, priority, expected) in [(CGFloat(1), MarkerLabelLayout.Priority.other, false),
                                               (2, .other, true), (0.0625, .selected, true)] {
                let before = probe.calls
                let canvas = Canvas { context, _ in
                    style.label(probe.name(), id: "fixture", priority: priority,
                                at: CGPoint(x: 120, y: 30), scale: scale, in: context)?.draw(in: context)
                }.frame(width: 240, height: 100)
                _ = try #require(MapImage.rasterizedImage(canvas, scale: 1))
                #expect((probe.calls > before) == expected)
            }
        }
    }

    private final class NameProbe {
        var calls = 0
        func name() -> String { calls += 1; return "Fixture label" }
    }
}
