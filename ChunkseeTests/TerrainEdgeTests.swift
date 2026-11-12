import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(2))) @MainActor struct TerrainEdgeTests {
    private let size = CGSize(width: 32, height: 32)

    private enum Join: String, CaseIterable {
        case regionX, regionZ, chunkX, chunkZ

        var vertical: Bool { self == .regionX || self == .chunkX }
        var regionBoundary: Bool { self == .regionX || self == .regionZ }
        var regions: [RegionPosition] {
            guard regionBoundary else { return [.init(x: 0, z: 0)] }
            return vertical ? [.init(x: -1, z: 0), .init(x: 0, z: 0)]
                            : [.init(x: 0, z: -1), .init(x: 0, z: 0)]
        }
        var chunks: [ChunkPosition] {
            let first = regionBoundary ? -1 : 0, second = first + 1
            return vertical ? [.init(x: first, z: 0), .init(x: second, z: 0)]
                            : [.init(x: 0, z: first), .init(x: 0, z: second)]
        }
        func viewport(zoom: CGFloat, shift: CGFloat, centerAlongJoin: CGFloat = 8) -> MapViewport {
            let edge: CGFloat = regionBoundary ? 0 : 16
            let center = vertical ? CGPoint(x: edge - shift / zoom, y: centerAlongJoin)
                                  : CGPoint(x: centerAlongJoin, y: edge - shift / zoom)
            return MapViewport(center: center, scale: zoom)
        }
    }

    @Test func detailMeetsAtRegionAndInternalChunkEdgesWithoutExposingTheBase() throws {
        let base = try tile(red: 0.1, green: 0.2, blue: 0.8)
        let otherBase = try tile(red: 0.8, green: 0.2, blue: 0.1)
        let mask = try tile(red: 0, green: 0, blue: 0).image
        for join in Join.allCases {
            for zoom: CGFloat in [8, 16] {
                for scale: CGFloat in [1, 2] {
                    for shift: CGFloat in [0, 0.25, 0.5] {
                        for opacity: CGFloat in [1, 0.5] {
                            for shadows in [false, true] {
                                let viewport = join.viewport(zoom: zoom, shift: shift)
                                let regions = viewport.visibleRegions(in: size, among: Set(join.regions))
                                try #require(regions.count == (join.regionBoundary ? 2 : 1))
                                // Opaque detail must hide either base. Translucent detail
                                // over one base must blend identically on both sides.
                                var tiles = Dictionary(uniqueKeysWithValues: regions.map { ($0, base) })
                                if join.regionBoundary && opacity == 1 { tiles[join.regions[1]] = otherBase }
                                let detail = try tile(red: 0.1, green: 0.7, blue: 0.3, alpha: opacity,
                                                      side: 16 * GameModelRenderer.blockTextureSide)
                                let images = Dictionary(uniqueKeysWithValues: join.chunks.map { ($0, detail) })
                                let input = drawingInput(shadows: shadows)
                                let expected = try reference(base: base, detail: detail,
                                    shadow: shadows ? mask : nil, scale: scale)
                                try checkTerrain(viewport: viewport, regions: regions, tiles: tiles, detail: images,
                                    shadow: shadows ? mask : nil, input: input, scale: scale, reference: expected,
                                    context: "\(join.rawValue), zoom \(zoom), display \(scale), shift \(shift), opacity \(opacity), shadows \(shadows)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func averagedTerrainAndShadowsMeetAtFractionalRegionEdges() throws {
        let base = try tile(red: 0.1, green: 0.2, blue: 0.8)
        let mask = try tile(red: 0, green: 0, blue: 0).image
        for join in [Join.regionX, .regionZ] {
            for zoom: CGFloat in [1, 4] {
                for scale: CGFloat in [1, 2] {
                    for shift: CGFloat in [0, 0.25, 0.5] {
                        for shadows in [false, true] {
                            // The reference fills the view, so stay inside the supplied
                            // regions along the join even when the view spans 32 blocks.
                            let viewport = join.viewport(zoom: zoom, shift: shift, centerAlongJoin: 256)
                            let regions = viewport.visibleRegions(in: size, among: Set(join.regions))
                            try #require(regions.count == 2)
                            let coverage = try regions.map { try #require(viewport.viewRect(for: $0, in: size)) }
                                .reduce(CGRect.null) { $0.union($1) }
                            try #require(coverage.contains(CGRect(origin: .zero, size: size)))
                            let tiles = Dictionary(uniqueKeysWithValues: regions.map { ($0, base) })
                            let expected = try reference(base: base, detail: nil,
                                shadow: shadows ? mask : nil, scale: scale)
                            try checkTerrain(viewport: viewport, regions: regions, tiles: tiles, detail: [:],
                                shadow: shadows ? mask : nil, input: drawingInput(shadows: shadows), scale: scale,
                                reference: expected,
                                context: "\(join.rawValue), zoom \(zoom), display \(scale), shift \(shift), shadows \(shadows)")
                        }
                    }
                }
            }
        }
    }

    @Test func zoomedOutTerrainKeepsItsExistingFilteredEdges() throws {
        let first = try tile(red: 0.1, green: 0.2, blue: 0.8)
        let second = try tile(red: 0.8, green: 0.2, blue: 0.1)
        let mask = try tile(red: 0, green: 0, blue: 0).image
        for join in [Join.regionX, .regionZ] {
            for zoom: CGFloat in [0.25, 0.5] {
                for scale: CGFloat in [1, 2] {
                    for shift: CGFloat in [0, 0.25, 0.5] {
                        for shadows in [false, true] {
                            let viewport = join.viewport(zoom: zoom, shift: shift)
                            let regions = viewport.visibleRegions(in: size, among: Set(join.regions))
                            try #require(regions.count == 2)
                            let tiles = [join.regions[0]: first, join.regions[1]: second]
                            // This is the previous SwiftUI image composition, including
                            // its low-zoom padding. It does not use the new pixel helper.
                            let reference = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                                for region in regions {
                                    guard let tile = tiles[region],
                                          let bounds = viewport.viewRect(for: region, in: size) else { continue }
                                    let rect = bounds.insetBy(dx: -0.5, dy: -0.5)
                                    context.draw(Image(decorative: tile.image, scale: 1).interpolation(.medium), in: rect)
                                    if shadows {
                                        var layer = context
                                        layer.opacity = 0.22
                                        layer.draw(Image(decorative: mask, scale: 1).interpolation(.medium), in: rect)
                                    }
                                }
                            }
                            let input = drawingInput(shadows: shadows)
                            let actual = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                                MapView.drawTerrain(viewport: viewport, regions: regions, image: { tiles[$0] },
                                    input: input, shadow: { _ in shadows ? mask : nil }, increasedContrast: false,
                                    in: context, size: size)
                            }
                            try check(render(actual, scale: scale), reference: render(reference, scale: scale),
                                context: "low zoom \(zoom), \(join.rawValue), display \(scale), shift \(shift), shadows \(shadows)")
                        }
                    }
                }
            }
        }
    }

    private func drawingInput(shadows: Bool) -> MapDrawingInput {
        var choices = MapPresentation()
        choices.lightingMode = .daylight
        choices.castsShadows = shadows
        return MapDrawingInput(presentation: choices, heightScale: nil, savedLighting: nil)
    }

    private func tile(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1,
                      side: Int = RegionTileRenderer.side) throws -> MapTileImage {
        let context = try #require(MapImage.imageContext(width: side, height: side))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return MapTileImage(try #require(context.makeImage()))
    }

    private func render<V: View>(_ canvas: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: canvas.frame(width: size.width, height: size.height))
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func reference(base: MapTileImage, detail: MapTileImage?, shadow: CGImage?, scale: CGFloat) throws -> CGImage {
        // One unbroken image is the reference for neighboring images of identical color.
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.draw(Image(decorative: base.image, scale: 1).interpolation(.none), in: rect)
            if let detail { context.draw(Image(decorative: detail.image, scale: 1).interpolation(.none), in: rect) }
            if let shadow {
                var layer = context
                layer.opacity = 0.22
                layer.draw(Image(decorative: shadow, scale: 1).interpolation(.none), in: rect)
            }
        }
        return try render(canvas, scale: scale)
    }

    private func checkTerrain(viewport: MapViewport, regions: [RegionPosition], tiles: [RegionPosition: MapTileImage],
                              detail: [ChunkPosition: MapTileImage], shadow: CGImage?, input: MapDrawingInput,
                              scale: CGFloat, reference: CGImage, context: String) throws {
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { drawing, size in
            MapView.drawTerrain(viewport: viewport, regions: regions, image: { tiles[$0] }, input: input,
                shadow: { _ in shadow }, detail: detail, increasedContrast: false, in: drawing, size: size)
        }
        try check(render(canvas, scale: scale), reference: reference, context: "screen: \(context)")
        let side = Int(size.width * scale)
        let destination = try #require(MapImage.imageContext(width: side, height: side))
        for region in regions {
            let tile = try #require(tiles[region])
            try #require(MapImage.drawTerrainLayer(tile, region: region, viewport: viewport, size: size, scale: scale,
                input: input, contrast: .standard, shadow: shadow, detail: detail, into: destination))
        }
        try check(#require(destination.makeImage()), reference: reference, context: "export: \(context)")
    }

    private func check(_ actual: CGImage, reference: CGImage, context: String) throws {
        try #require(actual.width == reference.width && actual.height == reference.height)
        let actualPixels = try pixels(actual)
        let expected = try pixels(reference)
        try #require(actualPixels.count == expected.count)
        let differentBytes = zip(actualPixels, expected).filter { $0 != $1 }.count
        #expect(differentBytes == 0, "\(context)")
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        // ImageRenderer and the export context may expose different pixel formats.
        let context = try #require(MapImage.imageContext(width: image.width, height: image.height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try ItemPictureFixture.pixels(#require(context.makeImage())).bytes
    }
}
