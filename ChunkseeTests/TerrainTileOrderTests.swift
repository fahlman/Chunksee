import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) @MainActor struct TerrainTileOrderTests {
    private let neighbors = [RegionPosition(x: -1, z: -1), .init(x: -1, z: 0),
                             .init(x: 0, z: -1), .init(x: 0, z: 0)]

    @Test func equalDistanceRegionsHaveOneOrderAcrossSavedCatalogs() {
        let farther = RegionPosition(x: 1, z: 1)
        let expected = neighbors + [farther]
        let viewport = MapViewport(center: .zero, scale: 0.125)
        let size = CGSize(width: 512, height: 512)
        for shift in expected.indices {
            let rotated = Array(expected[shift...] + expected[..<shift])
            for input in [rotated, Array(rotated.reversed())] {
                let saved = Set(input + [.init(x: 100, z: 100), .init(x: Int.max, z: 0)])
                #expect(viewport.visibleRegions(in: size, among: saved) == expected)
            }
        }
        // A new nearest tile still wins; the tie break does not replace distance priority.
        let moved = MapViewport(center: CGPoint(x: 768, y: 768), scale: 0.125)
        #expect(moved.visibleRegions(in: size, among: Set(expected)).first == farther)
    }

    @Test func overlappingTerrainEdgesRepeatAcrossCatalogInsertionOrders() throws {
        let viewport = MapViewport(center: .zero, scale: 0.125)
        let size = CGSize(width: 128, height: 128)
        let colors: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        var images: [RegionPosition: MapTileImage] = [:]
        for (region, color) in zip(neighbors, colors) {
            let context = try #require(MapImage.imageContext(width: 8, height: 8))
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            images[region] = MapTileImage(image)
        }
        func pixels(_ order: [RegionPosition]) throws -> Data {
            let input = MapDrawingInput(presentation: MapPresentation(), heightScale: nil, savedLighting: nil)
            let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                MapView.drawTerrain(viewport: viewport, regions: order, image: { images[$0] }, input: input, in: context, size: size)
            }.frame(width: size.width, height: size.height)
            let context = try #require(MapImage.imageContext(width: 256, height: 256))
            try #require(MapImage.drawImageLayer(canvas, size: size, scale: 2, into: context))
            return try #require(context.makeImage()?.dataProvider?.data) as Data
        }
        let reference = try pixels(neighbors)
        // The fixture must see the real overlap: reversed painting changes the boundary pixels.
        #expect(try pixels(Array(neighbors.reversed())) != reference)
        for shift in neighbors.indices {
            let rotated = Array(neighbors[shift...] + neighbors[..<shift])
            for input in [rotated, Array(rotated.reversed())] {
                #expect(try pixels(viewport.visibleRegions(in: size, among: Set(input))) == reference)
            }
        }
    }
}
