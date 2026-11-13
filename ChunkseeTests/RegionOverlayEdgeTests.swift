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

        func viewport(zoom: CGFloat, shift: CGFloat, crossShift: CGFloat) -> MapViewport {
            let center = self == .vertical ? CGPoint(x: -shift / zoom, y: 256 - crossShift / zoom)
                                          : CGPoint(x: 256 - crossShift / zoom, y: -shift / zoom)
            return MapViewport(center: center, scale: zoom)
        }
    }

    @Test func uniformTimeSpentKeepsItsOpacityAcrossRegionJoins() throws {
        let image = try #require(HeatMap.image(fromTicks: Array(repeating: HeatMap.maximumTicks, count: 1024)))
        let pixel = try ItemPictureFixture.pixels(image).color(0, 0)
        try #require(pixel == [178, 0, 0, 178])
        for join in Join.allCases {
            try checkJoins([image, image], join: join, uniform: true, layer: \.heatMap)
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
            try checkJoins(images, join: join, uniform: false, layer: \.heatMap)
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
            let first = try ItemPictureFixture.pixels(images[0])
            let second = try ItemPictureFixture.pixels(images[1])
            let leftAlpha = join == .vertical ? first.color(31, 16)[3] : first.color(16, 31)[3]
            let rightAlpha = join == .vertical ? second.color(0, 16)[3] : second.color(16, 0)[3]
            try #require(leftAlpha == SlimeChunks.pixel.alpha && rightAlpha == SlimeChunks.pixel.alpha)
            try checkJoins(images, join: join, uniform: false, layer: \.slimeChunks)
        }
    }

    private func checkJoins(_ images: [CGImage], join: Join, uniform: Bool,
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
                // Keep the exact/quarter/half-pixel joins. The extra phase puts both
                // axes between source-pixel boundaries, requiring one exact sample.
                let phases: [(CGFloat, CGFloat)] = [(0, 0), (0.25, 0), (0.5, 0)]
                    + (uniform ? [] : [(0.125, 0.125)])
                for (shift, crossShift) in phases {
                    let viewport = join.viewport(zoom: zoom, shift: shift, crossShift: crossShift)
                    let visible = viewport.visibleRegions(in: size, among: Set(join.regions))
                    try #require(visible.count == 2)
                    let references: [CGImage]
                    if uniform {
                        references = [images[0]]
                    } else {
                        let grid = try nearestReferences(images, join: join, viewport: viewport,
                                                         size: size, scale: displayScale)
                        references = grid.images
                        if crossShift != 0 { try #require(!grid.hasTies && references.count == 1) }
                    }
                    for background in [Color.clear, Color(red: 0.2, green: 0.3, blue: 0.6)] {
                        let actual = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                            MapView.drawOverlays(viewport: viewport, regions: visible, content: content,
                                portalStatus: { _ in nil }, in: context, size: size)
                        }
                        let expected = references.map { reference in
                            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                                context.draw(Image(decorative: reference, scale: 1).interpolation(.none),
                                             in: CGRect(origin: .zero, size: size))
                            }
                        }
                        let expectedPixels = try expected.map { try pixels(render($0, size: size, scale: displayScale)) }
                        let screen = try pixels(render(actual, size: size, scale: displayScale))
                        let destination = try #require(MapImage.imageContext(width: Int(side * displayScale),
                                                                            height: Int(side * displayScale)))
                        try #require(MapImage.drawImageLayer(actual, size: size, scale: displayScale, into: destination))
                        let expectedExported = try expected.map { reference in
                            let target = try #require(MapImage.imageContext(width: Int(side * displayScale),
                                                                          height: Int(side * displayScale)))
                            try #require(MapImage.drawImageLayer(reference, size: size, scale: displayScale, into: target))
                            return try pixels(#require(target.makeImage()))
                        }
                        let exportedImage = try #require(destination.makeImage())
                        let exported = try pixels(exportedImage)
                        let context = "\(join.rawValue), zoom \(zoom), display \(displayScale), shift \(shift), cross \(crossShift), background \(background)"
                        let screenMismatches = try mismatches(screen, allowed: expectedPixels, width: exportedImage.width)
                        let exportMismatches = try mismatches(exported, allowed: expectedExported, width: exportedImage.width)
                        #expect(screenMismatches.isEmpty, "screen: \(context)")
                        #expect(exportMismatches.isEmpty, "export: \(context)")
                    }
                }
            }
        }
    }

    private func nearestReferences(_ images: [CGImage], join: Join, viewport: MapViewport,
                                   size: CGSize, scale: CGFloat) throws -> (images: [CGImage], hasTies: Bool) {
        // A stretched joined image is not a reliable oracle at exact nearest-sample
        // ties: it can pick a different neighbor from the separate tiles.
        // Choose the owning region in world coordinates, then only its nearest texels.
        // Build output-sized images so reference rendering introduces no sampling ties.
        let parts = try images.map { try ItemPictureFixture.pixels($0) }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        var choices = Array(repeating: [UInt8](), count: 4)
        var hasTies = false
        func nearest(_ coordinate: CGFloat, lowerOnTie: Bool) -> Int {
            let cell = coordinate.rounded(.down)
            let index = Int(cell) - (lowerOnTie && coordinate == cell ? 1 : 0)
            return min(31, max(0, index))
        }
        for y in 0..<height {
            for x in 0..<width {
                let worldX = viewport.center.x + ((CGFloat(x) + 0.5) / scale - size.width / 2) / viewport.scale
                let worldZ = viewport.center.y + ((CGFloat(y) + 0.5) / scale - size.height / 2) / viewport.scale
                let region = RegionPosition(x: Int((worldX / 512).rounded(.down)),
                                            z: Int((worldZ / 512).rounded(.down)))
                let source = parts[try #require(join.regions.firstIndex(of: region))]
                let sourceX = (worldX - CGFloat(region.x) * 512) / 16
                let sourceY = (worldZ - CGFloat(region.z) * 512) / 16
                let xs = [nearest(sourceX, lowerOnTie: true), nearest(sourceX, lowerOnTie: false)]
                let ys = [nearest(sourceY, lowerOnTie: true), nearest(sourceY, lowerOnTie: false)]
                hasTies = hasTies || xs[0] != xs[1] || ys[0] != ys[1]
                for choice in 0..<4 {
                    choices[choice].append(contentsOf: source.color(xs[choice % 2], ys[choice / 2]))
                }
            }
        }
        var seen = Set<[UInt8]>()
        let references = try choices.filter { seen.insert($0).inserted }.map {
            try #require(CGImage.rgba($0, width: width, height: height))
        }
        return (references, hasTies)
    }

    private struct PixelMismatch {
        let x: Int
        let y: Int
        let actual: [UInt8]
        let allowed: [[UInt8]]
    }

    private func mismatches(_ actual: [UInt8], allowed references: [[UInt8]], width: Int) throws -> [PixelMismatch] {
        try #require(!references.isEmpty && references.allSatisfy { $0.count == actual.count })
        return stride(from: 0, to: actual.count, by: 4).compactMap { offset in
            let pixel = Array(actual[offset..<offset + 4])
            let allowed = references.map { Array($0[offset..<offset + 4]) }
            guard !allowed.contains(pixel) else { return nil }
            return PixelMismatch(x: offset / 4 % width, y: offset / 4 / width, actual: pixel, allowed: allowed)
        }
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
