import ChunkseeKit
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct StructureSceneTests {
    private let size = CGSize(width: 400, height: 200)
    private let center = CGPoint(x: 200, y: 100)

    private func structure() throws -> StructureMarker {
        let nbt = NBT.compound(["structures": .compound(["starts": .compound([
            "minecraft:stronghold": .compound(["ChunkX": .int(-7), "ChunkZ": .int(-3),
                "Children": .list([.compound([
                    "id": .string("minecraft:shstart"), "BB": .intArray([-101, 40, -43, -2, 59, 16]),
                ]), .compound([
                    "id": .string("minecraft:shpr"), "BB": .intArray([-86, 45, -28, -81, 49, -23]),
                ])]),
            ]),
        ])])])
        return StructureMarker(try #require(StructureStart.starts(inChunk: nbt).first))
    }

    @Test func structureDrawingPickingAndAccessibilityShareCoordinatesAndBadgeGeometry() throws {
        let marker = try structure()
        var content = MapContent(); content.structures = [marker]; content.selectedItem = .structure(marker.id)
        let viewport = MapViewport(center: marker.position, scale: 2)
        let structure = try #require(content.scene(viewport: viewport, size: size).structures.first)
        let item = structure.item
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        let hit = try #require(content.hit(at: center, viewport: viewport, size: size))
        #expect(item.point == center && item.frame == CGRect(x: 191, y: 91, width: 18, height: 18))
        #expect(location.frame == item.frame && location.anchor == marker.position)
        #expect(location.position == CGPoint(x: -51, y: -13) && hit.position == location.position)
        #expect(location.y == 50 && hit.y == location.y)
        #expect(location.target == hit.target && hit.target == item.target)
        #expect(location.name == "Stronghold" && item.labelPriority == .selected)
        #expect(structure.outline == CGRect(x: 100, y: 40, width: 200, height: 120))
        #expect(structure.portalRoom == viewport.viewPoint(for: try #require(marker.portalRoom), in: size))
        let reach = item.style.geometry.hitRadius(at: viewport.scale)
        #expect(content.target(at: CGPoint(x: center.x + reach, y: center.y), viewport: viewport, size: size) == item.target)
        #expect(content.target(at: CGPoint(x: center.x + reach + 0.01, y: center.y), viewport: viewport, size: size) == nil)
        // A legacy marker without saved vertical bounds must still ask the terrain for Y.
        content.structures[0].y = nil
        #expect(content.hit(at: center, viewport: viewport, size: size)?.y == nil)
        #expect(content.accessibleLocations(viewport: viewport, size: size).first?.y == nil)
    }

    @Test func structuresStayBelowPointsAndKeepNearestThenLaterPicking() throws {
        let first = try structure()
        var second = first; second.id = "second"; second.y = 72
        let viewport = MapViewport(center: first.position, scale: 2)
        var content = MapContent(); content.structures = [first, second]
        #expect(content.hit(at: center, viewport: viewport, size: size)?.y == 72)
        content.structures.reverse()
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.structure(first.id)))
        content.structures[1].bounds = first.bounds.offsetBy(dx: 5, dy: 0)
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.structure(second.id)))
        #expect(content.target(at: CGPoint(x: 210, y: 100), viewport: viewport, size: size) == .row(.structure(first.id)))
        let spawner = PlaceMarker(Spawner(x: -51, y: 48, z: -13, mob: "minecraft:zombie"))
        content.places = [spawner]
        #expect(content.target(at: center, viewport: viewport, size: size) == .row(.place(spawner.id)))
        #expect(content.accessibleLocations(viewport: viewport, size: size).map(\.target) == [
            .row(.structure(second.id)), .row(.structure(first.id)), .row(.place(spawner.id)),
        ])
    }

    @Test func visibleStructureAreasDoNotCreateOffscreenBadgesOrPortalRoomClickTargets() throws {
        var marker = try structure()
        marker.bounds = CGRect(x: 0, y: 0, width: 8_000, height: 160)
        marker.portalRoom = CGPoint(x: 20, y: 80)
        let viewport = MapViewport(center: CGPoint(x: 10, y: 80), scale: 1)
        var content = MapContent(); content.structures = [marker]
        let structure = try #require(content.scene(viewport: viewport, size: size).structures.first)
        #expect(structure.outline.intersects(CGRect(origin: .zero, size: size)))
        #expect(structure.item.point.x > size.width)
        #expect(content.accessibleLocations(viewport: viewport, size: size).isEmpty)
        #expect(content.target(at: center, viewport: viewport, size: size) == nil)
        #expect(content.target(at: try #require(structure.portalRoom), viewport: viewport, size: size) == nil)
        content.structures[0].bounds = marker.bounds.offsetBy(dx: 50_000, dy: 0)
        #expect(content.scene(viewport: viewport, size: size).structures.isEmpty)
    }

    @Test func mapExportKeepsAreaAndPortalRoomWhenTheStructureBadgeIsOffscreen() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 20, y: 80))
        defer { map.close() }
        var marker = try structure()
        marker.bounds = CGRect(x: 0, y: 0, width: 8_000, height: 160)
        marker.portalRoom = CGPoint(x: 20, y: 80)
        var content = MapContent(); content.structures = [marker]
        func pixels(_ content: MapContent, scale: CGFloat, name: String) throws -> Data {
            map.viewport.scale = scale
            let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 1))
            let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
            let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            Attachment.record(pixels, named: name, as: .png)
            return try #require(pixels.dataProvider?.data) as Data
        }
        let empty = try pixels(MapContent(), scale: 0.125, name: "empty-structure-area")
        #expect(try pixels(content, scale: 0.125, name: "hidden-structure-area") == empty)
        let withRoom = try pixels(content, scale: 0.25, name: "structure-area-with-room")
        content.structures[0].portalRoom = nil
        let withoutRoom = try pixels(content, scale: 0.25, name: "structure-area-without-room")
        #expect(withRoom != withoutRoom)
        #expect(withoutRoom != empty)
    }
}
