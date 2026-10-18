import ChunkseeKit
import Foundation
import ImageIO
import Testing
@testable import Chunksee

@Suite struct PointMarkersTests {
    private let size = CGSize(width: 200, height: 140)

    private func places() -> [PlaceMarker] {
        var markers = (0..<11_000).map { i in
            PlaceMarker(Spawner(x: 100_000 + i * 512, y: 64, z: 200_000 + (i % 7) * 512, mob: "minecraft:zombie"))
        }
        markers += [-1025, -513, -512, -1, 0, 511, 512, 513, 1023].map {
            PlaceMarker(Spawner(x: $0, y: 64, z: -1, mob: "minecraft:skeleton"))
        }
        markers += [PlaceMarker(NetherPortal(dimension: "minecraft:overworld", blocks: [
            .init(x: -1, y: 64, z: 0), .init(x: 0, y: 64, z: 0),
        ]))]
        return markers
    }

    private func creatures() -> [CreatureMarker] {
        [-513.0, -512.1, -512, -0.1, 0, 511.9, 512, 513].enumerated().compactMap { i, x in
            CreatureMarker(Creature(id: "minecraft:wolf", x: x, y: 64, z: 0, customName: "Pet \(i)", owner: UUID()), dimension: "minecraft:overworld")
        }
    }

    @Test func elevenThousandOffscreenMarkersUseNearbyCandidatesAndKeepFullScanLocations() {
        let places = places(), creatures = creatures()
        var content = MapContent()
        content.places = places; content.creatures = creatures
        content.selection = .creature(creatures[3])
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        for center in [-512.0, 0, 512] {
            for scale in [0.0625, 0.125, 0.249, 0.25, 2, 32] {
                let viewport = MapViewport(center: CGPoint(x: center, y: 0), scale: scale)
                for shown in [Set<PlaceGroup>([.spawner, .portal]), [.portal], []] {
                    content.shownPlaceGroups = shown
                    let expectedPlaces = places.filter {
                        shown.contains($0.group) && (scale >= 0.125 || $0.group == .portal) && bounds.contains(viewport.viewPoint(for: $0.position, in: size))
                    }
                    let expectedCreatures = creatures.filter {
                        (scale >= 0.25 || content.selection == .creature($0)) && bounds.contains(viewport.viewPoint(for: $0.position, in: size))
                    }
                    let locations = content.accessibleLocations(viewport: viewport, size: size)
                    #expect(locations.map(\.id) == expectedPlaces.map { "place-" + $0.id } + expectedCreatures.map { "creature-" + $0.id })
                    #expect(locations.map(\.name) == expectedPlaces.map(\.name) + expectedCreatures.map(\.name))
                    #expect(locations.map(\.position) == expectedPlaces.map(\.position) + expectedCreatures.map(\.position))
                    #expect(locations.map(\.target) == expectedPlaces.map { MapTarget.row(.place($0.id)) } + expectedCreatures.map { MapTarget.row(.creature($0.id)) })
                    if scale == 2 && shown.contains(.spawner) {
                        let candidates = content.nearbyPlaces(viewport: viewport, size: size)
                        #expect(candidates.count < 20)
                        print("Point marker candidates: \(candidates.count) / \(places.count), center \(center), scale \(scale)")
                    }
                }
            }
        }
        content.shownCreatureGroups = []
        #expect(content.nearbyCreatures(viewport: .init(), size: size).isEmpty)
    }

    @Test func hitDistancesPortalPriorityAndLaterItemTiesMatchTheFullList() {
        var content = MapContent()
        let places = places(), creatures = creatures()
        content.places = places; content.creatures = creatures
        content.selection = .creature(creatures[3])
        func nearest<Marker>(_ values: [Marker], viewport: MapViewport, point: CGPoint, reach: (Marker) -> CGFloat, position: (Marker) -> CGPoint) -> Marker? {
            var best: Marker?, distance = CGFloat.infinity
            for value in values {
                let location = viewport.viewPoint(for: position(value), in: size)
                let candidate = hypot(location.x - point.x, location.y - point.y)
                if candidate <= reach(value), candidate <= distance { best = value; distance = candidate }
            }
            return best
        }
        for scale in [0.0625, 0.125, 0.25, 2, 32] {
            let viewport = MapViewport(center: CGPoint(x: 512, y: 0), scale: scale)
            for x in [-513.0, -512.1, -0.1, 0, 511.5, 512, 512.5, 513] {
                for offset in [0.0, 12, 12.01, 14, 14.01, 15, 15.01] {
                    var point = viewport.viewPoint(for: CGPoint(x: x, y: 0), in: size)
                    point.y += offset
                    var expected: MapTarget?
                    if let portal = nearest(places.filter { $0.portal != nil }, viewport: viewport, point: point, reach: { _ in 14 }, position: \.position) {
                        expected = .row(.place(portal.id))
                    } else if let pet = nearest(creatures.filter { scale >= 0.25 || content.selection == .creature($0) }, viewport: viewport,
                                                point: point, reach: { content.selection == .creature($0) ? 15 : 12 }, position: \.position) {
                        expected = .row(.creature(pet.id))
                    } else if scale >= 0.125, let place = nearest(places, viewport: viewport, point: point, reach: { $0.portal != nil ? 14 : 12 }, position: \.position) {
                        expected = .row(.place(place.id))
                    }
                    #expect(content.target(at: point, viewport: viewport, size: size) == expected)
                }
            }
        }
    }

    @Test func exportPixelsMatchAFullScanClippedReference() throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(World(contentsOf: world).dimension("overworld"))
        let map = MapModel(dimension: dimension, center: .zero)
        defer { map.close() }
        let places = places(), creatures = creatures()
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        for scale in [0.125, 2.0] {
            map.viewport = MapViewport(center: .zero, scale: scale)
            var content = MapContent(), reference = MapContent()
            content.places = places; content.creatures = creatures; content.selection = .creature(creatures[3])
            reference.selection = content.selection
            reference.places = places.filter { (scale >= 0.125 || $0.group == .portal) && bounds.contains(map.viewport.viewPoint(for: $0.position, in: size)) }
            reference.creatures = creatures.filter { (scale >= 0.25 || content.selection == .creature($0)) && bounds.contains(map.viewport.viewPoint(for: $0.position, in: size)) }
            let rendered = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
            let expected = try #require(MapImage.render(map, content: reference, portalStatus: { _ in nil }, size: size, scale: 2))
            #expect(rendered.data == expected.data)
        }
    }

    @Test func liveIndexReplacementMovesAddsAndRemovesBucketsWithoutCrossingDimensions() async throws {
        let spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let nether = url.appendingPathComponent("dimensions/minecraft/the_nether/region")
        try FileManager.default.createDirectory(at: nether, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([spec])).write(to: nether.appendingPathComponent("r.0.0.mca"))
        let state = MovingMarkers()
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil,
                                       readRegion: { dimension, _ in await state.read(dimension.id) })
        resources.refreshDelay = .zero
        await resources.index.waitForIndex()
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let other = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        overworld.visibility.places = [.spawner]; other.visibility.places = [.spawner]
        overworld.visibility.creatures = [.pet]
        let before = overworld.mapContent
        let viewport = MapViewport(center: CGPoint(x: 513.5, y: 0.5), scale: 32)
        let small = CGSize(width: 8, height: 8)
        #expect(before.nearbyPlaces(viewport: viewport, size: small).isEmpty)
        for step in [1, 2] {
            await state.move(to: step)
            resources.worldChanged([url.appendingPathComponent("dimensions/minecraft/overworld/entities/r.0.0.mca")])
            await resources.waitForRefresh()
            await resources.index.waitForIndex()
            let content = overworld.mapContent
            #expect(content.nearbyPlaces(viewport: viewport, size: small).count == (step == 1 ? 1 : 0))
            #expect(content.nearbyCreatures(viewport: viewport, size: small).count == (step == 1 ? 1 : 0))
            #expect(other.mapContent.places.map(\.mob) == ["minecraft:blaze"])
            #expect(before.places.first?.position.x == 511.5) // captured snapshot stays immutable
        }
        resources.close()
        await resources.waitUntilClosed()
    }

    @Test func fitWorldAndUnusualPositionsDoNotEnumerateEmptySpaceOrTrap() {
        var unusual = PlaceMarker(Spawner(x: 0, y: 64, z: 0, mob: nil))
        unusual.position = CGPoint(x: Double.greatestFiniteMagnitude, y: .infinity)
        let snapshot = PointMarkers(places() + [unusual])
        let viewport = MapViewport(center: .zero, scale: MapViewport.scaleRange.lowerBound)
        let candidates = snapshot.candidates(in: CGRect(origin: .zero, size: size), viewport: viewport, size: size)
        #expect(candidates.count == snapshot.all.count)
        let invalid = CGRect(x: -Double.infinity, y: 0, width: .infinity, height: 20)
        #expect(snapshot.candidates(in: invalid, viewport: viewport, size: size).count == snapshot.all.count)
    }

    private actor MovingMarkers {
        private var step = 0
        func move(to step: Int) { self.step = step }
        func read(_ dimension: String) -> RegionData {
            var data = RegionData()
            if dimension == "minecraft:the_nether" {
                data.contents.spawners = [Spawner(x: 513, y: 64, z: 0, mob: "minecraft:blaze")]
            } else if step < 2 {
                let x = step == 0 ? 511 : 513
                data.contents.spawners = [Spawner(x: x, y: 64, z: 0, mob: "minecraft:zombie")]
                data.creatures = [Creature(id: "minecraft:wolf", x: Double(x) + 0.5, y: 64, z: 0.5, owner: UUID())]
            }
            return data
        }
    }
}
