import ChunkseeKit
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BiomeSceneTests {
    private let size = CGSize(width: 400, height: 200)

    @Test func projectedAreasKeepNegativeChunksAndSeparateDiagonalNeighbors() throws {
        let areas = BiomeScanner.areas(from: [
            .init(x: -1, z: -1): "minecraft:forest", .init(x: 0, z: -1): "minecraft:forest",
            .init(x: -1, z: 0): "minecraft:forest", .init(x: 1, z: 1): "minecraft:forest",
            .init(x: 1, z: 0): "custom:forest",
        ])
        #expect(areas.count == 3)
        let joined = try #require(areas.first { $0.chunkCount == 3 })
        #expect(joined.id == "minecraft:forest@-1,-1" && joined.group.id == "minecraft:forest")
        #expect(joined.position == CGPoint(x: -8, y: -8))
        #expect(joined.bounds == CGRect(x: -16, y: -16, width: 32, height: 32))
        #expect(joined.chunks.contains(joined.position))
        #expect(joined.chunks.contains(CGPoint(x: 8, y: -8)))
        #expect(joined.chunks.contains(CGPoint(x: -8, y: 8)))
        #expect(!joined.chunks.contains(CGPoint(x: 8, y: 8)))
        #expect(areas.contains { $0.group.id == "custom:forest" && $0.position == CGPoint(x: 24, y: 8) })
        #expect(areas.contains { $0.id == "minecraft:forest@1,1" && $0.bounds == CGRect(x: 16, y: 16, width: 16, height: 16) })
    }

    @Test func visibleAreaDoesNotRequireItsRepresentativePointToBeOnscreen() throws {
        let bounds = CGRect(x: -32, y: -16, width: 1_600, height: 32)
        let area = BiomeArea(id: "long", group: .init(id: "minecraft:plains"), chunkCount: 200,
            position: CGPoint(x: 776, y: 8), bounds: bounds, chunks: Path(bounds), outline: Path(bounds))
        var content = MapContent(); content.biomeAreas = [area]
        var viewport = MapViewport(center: CGPoint(x: -8, y: 8), scale: 2)
        let scene = content.scene(viewport: viewport, size: size)
        let item = try #require(scene.biomeAreas.first)
        #expect(item.frame == CGRect(x: 152, y: 52, width: 3_200, height: 64))
        #expect(item.point.x > size.width && scene.accessibleLocations.isEmpty)
        #expect(content.hit(at: CGPoint(x: 200, y: 100), viewport: viewport, size: size) == nil)
        #expect(content.scene(viewport: viewport, size: size, pickingAt: .zero).biomeAreas.isEmpty)
        #expect(try alpha(render(content, viewport: viewport, size: size), x: 200, y: 100) == 38)

        viewport.center = area.position
        let location = try #require(content.accessibleLocations(viewport: viewport, size: size).first)
        #expect(location.id == "biome-long" && location.name == "Plains")
        #expect(location.position == area.position && location.y == nil)
        #expect(location.target == .row(.biome(area.id)))
        #expect(location.frame.contains(CGPoint(x: 200, y: 100)))
        viewport.center = CGPoint(x: -5_000, y: -5_000)
        #expect(content.scene(viewport: viewport, size: size).biomeAreas.isEmpty)
    }

    @Test func accessibilityMarginDoesNotDrawOffscreenAreasOrAddPointerTargets() throws {
        let area = try #require(BiomeScanner.areas(from: [.init(x: 0, z: 0): "minecraft:plains"]).first)
        var content = MapContent(); content.biomeAreas = [area]
        let size = CGSize(width: 100, height: 100)
        let viewport = MapViewport(center: CGPoint(x: -54, y: 8), scale: 1)
        let scene = content.scene(viewport: viewport, size: size)
        let item = try #require(scene.biomeAreas.first)
        #expect(item.frame == CGRect(x: 104, y: 42, width: 16, height: 16))
        #expect(scene.accessibleLocations.map(\.target) == [.row(.biome(area.id))])
        #expect(scene.hit(at: item.point) == nil)
        let image = try render(content, viewport: viewport, size: size)
        #expect(try alpha(image, x: 99, y: 50) == 0)
        #expect(content.scene(viewport: MapViewport(center: CGPoint(x: -63, y: 8), scale: 1), size: size).biomeAreas.isEmpty)
    }

    @Test func exportKeepsBiomeHolesOutlinesAndMarkerPaintOrder() throws {
        var chunks: [ChunkPosition: String] = [:]
        for x in -1...1 { for z in -1...1 where x != 0 || z != 0 {
            chunks[.init(x: x, z: z)] = "minecraft:plains"
        } }
        var content = MapContent(); content.biomeAreas = BiomeScanner.areas(from: chunks)
        let viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 4)
        let image = try render(content, viewport: viewport, size: size)
        Attachment.record(image, named: "biome-with-hole", as: .png)
        #expect(try alpha(image, x: 200, y: 100) == 0) // Missing center chunk remains empty.
        #expect(try alpha(image, x: 136, y: 100) == 38) // Existing 15% fill, away from edges.
        #expect(try alpha(image, x: 168, y: 100) > 100) // Inner boundary is still outlined.
        #expect(try alpha(image, x: 232, y: 100) > 100)
        #expect(try alpha(image, x: 200, y: 68) > 100)
        #expect(try alpha(image, x: 200, y: 132) > 100)
        #expect(try alpha(image, x: 104, y: 100) > 100) // Outer boundary uses the same edge projection.
        #expect(try alpha(image, x: 296, y: 100) > 100)
        #expect(try alpha(image, x: 200, y: 4) > 100)
        #expect(try alpha(image, x: 200, y: 196) > 100)
        #expect(try alpha(image, x: 10, y: 10) == 0)

        content.places = [PlaceMarker(Spawner(x: -8, y: 64, z: 8, mob: "minecraft:zombie"))]
        let withMarker = try render(content, viewport: viewport, size: size)
        Attachment.record(withMarker, named: "biome-below-marker", as: .png)
        content.biomeAreas = []
        let markerOnly = try render(content, viewport: viewport, size: size)
        #expect(try pixel(withMarker, x: 136, y: 100) == pixel(markerOnly, x: 136, y: 100))
        #expect(try alpha(withMarker, x: 136, y: 100) == 255)
    }

    private func render(_ content: MapContent, viewport: MapViewport, size: CGSize) throws -> CGImage {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: viewport.center)
        defer { map.close() }
        map.viewport = viewport
        let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 1, colorScheme: .light, locale: Locale(identifier: "en_US")))
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 { try pixel(image, x: x, y: y)[3] }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel
    }
}
