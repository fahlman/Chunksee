import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(2))) @MainActor struct RegionOverlayEdgeTests {
    private enum Join: String, CaseIterable {
        case vertical, horizontal

        var regions: [RegionPosition] {
            self == .vertical ? [.init(x: -1, z: 0), .init(x: 0, z: 0)]
                              : [.init(x: 0, z: -1), .init(x: 0, z: 0)]
        }

        func viewport(zoom: CGFloat, shift: CGFloat) -> MapViewport {
            let center = self == .vertical ? CGPoint(x: -shift / zoom, y: 256)
                                          : CGPoint(x: 256, y: -shift / zoom)
            return MapViewport(center: center, scale: zoom)
        }
    }

    @Test func uniformTimeSpentKeepsItsOpacityAcrossRegionJoins() throws {
        let image = try #require(HeatMap.image(fromTicks: Array(repeating: HeatMap.maximumTicks, count: 1024)))
        let pixel = try ItemPictureFixture.pixels(image).color(0, 0)
        try #require(pixel == [178, 0, 0, 178])
        for join in Join.allCases {
            try checkJoins([image, image], join: join, reference: image, uniform: true, layer: \.heatMap)
        }
    }

    @Test func chunkColorsAndTransparentChunksKeepTheirWorldPositions() throws {
        // Distinct colors and clear chunks catch flips, shifts and double blending
        // that a uniform image cannot. Both tiles come from the real image producer.
        let values = [0, HeatMap.minimumTicks, 72_000, HeatMap.maximumTicks]
        let images = try (0..<2).map { region in
            let ticks = (0..<1024).map { index in
                values[(index % 32 + (index / 32) * 2 + region) % values.count]
            }
            return try #require(HeatMap.image(fromTicks: ticks))
        }
        for join in Join.allCases {
            // One image containing both regions has no composited edge between them.
            let reference = try joinedImage(images, join: join)
            try checkJoins(images, join: join, reference: reference, uniform: false, layer: \.heatMap)
        }
    }

    @Test func slimeChunksKeepTheirOpacityAcrossRegionJoins() throws {
        for join in Join.allCases {
            // Select a deterministic, bounded fixture through Kit's real rule. The
            // two chunks nearest the viewport center must both exercise the seam.
            let seed = try #require((Int64(0)..<10_000).first { seed in
                if join == .vertical {
                    return World.isSlimeChunk(x: -1, z: 16, seed: seed) && World.isSlimeChunk(x: 0, z: 16, seed: seed)
                }
                return World.isSlimeChunk(x: 16, z: -1, seed: seed) && World.isSlimeChunk(x: 16, z: 0, seed: seed)
            })
            let images = try join.regions.map { try #require(SlimeChunks.image(region: $0, seed: seed)) }
            let reference = try joinedImage(images, join: join)
            let first = try ItemPictureFixture.pixels(images[0])
            let second = try ItemPictureFixture.pixels(images[1])
            let leftAlpha = join == .vertical ? first.color(31, 16)[3] : first.color(16, 31)[3]
            let rightAlpha = join == .vertical ? second.color(0, 16)[3] : second.color(16, 0)[3]
            try #require(leftAlpha == SlimeChunks.pixel.alpha && rightAlpha == SlimeChunks.pixel.alpha)
            try checkJoins(images, join: join, reference: reference, uniform: false, layer: \.slimeChunks)
        }
    }

    private func checkJoins(_ images: [CGImage], join: Join, reference: CGImage, uniform: Bool,
                            layer: WritableKeyPath<MapContent, [RegionPosition: CGImage]>) throws {
        try #require(images.count == 2 && images.allSatisfy { $0.width == 32 && $0.height == 32 })
        let input = MapDrawingInput(presentation: MapPresentation(), heightScale: nil, savedLighting: nil)
        var layers = MapContent(gameNames: .unavailable, terrain: input)
        layers[keyPath: layer] = Dictionary(uniqueKeysWithValues: zip(join.regions, images))
        let content = layers
        // Include Fit World's sub-preset scale as well as ordinary and close zoom.
        for zoom: CGFloat in [1.0 / 64, 1.0 / 16, 0.25, 1, 8, 16, 32] {
            let side = min(32, 512 * zoom)
            let size = CGSize(width: side, height: side)
            for displayScale: CGFloat in [1, 2] {
                for shift: CGFloat in [0, 0.25, 0.5] {
                    let viewport = join.viewport(zoom: zoom, shift: shift)
                    let visible = viewport.visibleRegions(in: size, among: Set(join.regions))
                    try #require(visible.count == 2)
                    let first = try #require(viewport.viewRect(for: join.regions[0], in: size))
                    let second = try #require(viewport.viewRect(for: join.regions[1], in: size))
                    let referenceRect = uniform ? CGRect(origin: .zero, size: size) : first.union(second)
                    for background in [Color.clear, Color(red: 0.2, green: 0.3, blue: 0.6)] {
                        let actual = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                            MapView.drawOverlays(viewport: viewport, regions: visible, content: content,
                                portalStatus: { _ in nil }, in: context, size: size)
                        }
                        let expected = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                            context.draw(Image(decorative: reference, scale: 1).interpolation(.none), in: referenceRect)
                        }
                        let expectedPixels = try pixels(render(expected, size: size, scale: displayScale))
                        let screen = try pixels(render(actual, size: size, scale: displayScale))
                        let destination = try #require(MapImage.imageContext(width: Int(side * displayScale),
                                                                            height: Int(side * displayScale)))
                        let referenceDestination = try #require(MapImage.imageContext(width: Int(side * displayScale),
                                                                                     height: Int(side * displayScale)))
                        try #require(MapImage.drawImageLayer(actual, size: size, scale: displayScale, into: destination))
                        // Each route is compared with one unbroken reference image
                        // drawn through that route, keeping its sampling rules intact.
                        try #require(MapImage.drawImageLayer(expected, size: size, scale: displayScale,
                                                            into: referenceDestination))
                        let exportedImage = try #require(destination.makeImage())
                        let exported = try pixels(exportedImage)
                        let expectedExported = try pixels(#require(referenceDestination.makeImage()))
                        let context = "\(join.rawValue), zoom \(zoom), display \(displayScale), shift \(shift), background \(background)"
                        #expect(screen == expectedPixels, "screen: \(context)")
                        #expect(exported == expectedExported, "export: \(context)")
                    }
                }
            }
        }
    }

    private func joinedImage(_ images: [CGImage], join: Join) throws -> CGImage {
        try #require(images.count == 2 && images.allSatisfy { $0.width == 32 && $0.height == 32 })
        let parts = try images.map { try ItemPictureFixture.pixels($0) }
        let width = join == .vertical ? 64 : 32
        let height = join == .vertical ? 32 : 64
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let region = join == .vertical ? x / 32 : y / 32
                bytes.append(contentsOf: parts[region].color(x % 32, y % 32))
            }
        }
        return try #require(CGImage.rgba(bytes, width: width, height: height))
    }

    private func render<V: View>(_ canvas: V, size: CGSize, scale: CGFloat) throws -> CGImage {
        try #require(MapImage.rasterizedImage(canvas.frame(width: size.width, height: size.height), scale: scale))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        // Compare one RGBA format across ImageRenderer and the export callback.
        let context = try #require(MapImage.imageContext(width: image.width, height: image.height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let normalized = try #require(context.makeImage())
        return try ItemPictureFixture.pixels(normalized).bytes
    }
}
