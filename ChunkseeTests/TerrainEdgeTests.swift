import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Synchronization
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
        var rectangles = try regions.map { region in
            ("region \(region.x),\(region.z)", try #require(viewport.viewRect(for: region, in: size)))
        }
        for chunk in detail.keys.sorted(by: { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }) {
            rectangles.append(("chunk \(chunk.x),\(chunk.z)", try #require(viewport.viewRect(for: chunk, in: size))))
        }
        try captureTransforms(rectangles: rectangles, scale: scale, context: context)
    }

    nonisolated private struct RectangleTransform: Codable, Sendable {
        let name: String
        let user: [Double]
        let device: [Double]

        init(name: String, rect: CGRect, context: CGContext) {
            self.name = name
            user = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
            let converted = context.convertToDeviceSpace(rect)
            device = [converted.minX, converted.minY, converted.width, converted.height].map(Double.init)
        }
    }

    nonisolated private struct TransformSample: Codable, Sendable {
        let ctm: [Double]
        let rectangles: [RectangleTransform]
    }

    nonisolated private struct TransformCapture: Sendable {
        var calls = 0
        var samples: [TransformSample] = []
    }

    nonisolated private struct TransformEvidence: Codable, Sendable {
        let context: String
        let displayScale: Double
        let width: Int
        let height: Int
        let callbackCount: Int
        let overflow: Bool
        let samples: [TransformSample]
    }

    private func captureTransforms(rectangles: [(String, CGRect)], scale: CGFloat, context: String) throws {
        // Observe a separate Canvas through each actual rendering path. Recording here
        // leaves the product drawing code and the preceding pixel assertions untouched.
        for route in ["screen", "export"] {
            // A renderer may invoke its callback more than once. Keep bounded evidence
            // without assuming its thread, and reject overflow after preserving the log.
            let capture = Mutex(TransformCapture())
            let probe = Canvas(opaque: false, rendersAsynchronously: false) { drawing, _ in
                drawing.withCGContext { pixels in
                    let ctm = pixels.ctm
                    let sample = TransformSample(ctm: [ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty].map(Double.init),
                        rectangles: rectangles.map { RectangleTransform(name: $0.0, rect: $0.1, context: pixels) })
                    capture.withLock { value in
                        value.calls += 1
                        if value.samples.count < 8 { value.samples.append(sample) }
                    }
                    // Keep the diagnostic layer nonempty; it never touches the map image.
                    pixels.setFillColor(CGColor(gray: 0, alpha: 1))
                    pixels.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
            let side = Int(size.width * scale)
            if route == "screen" {
                _ = try render(probe, scale: scale)
            } else {
                let destination = try #require(MapImage.imageContext(width: side, height: side))
                try #require(MapImage.drawImageLayer(probe, size: size, scale: scale, into: destination))
                _ = try #require(destination.makeImage())
            }
            let result = capture.withLock { $0 }
            let record = TransformEvidence(context: "\(route): \(context)", displayScale: Double(scale),
                width: side, height: side, callbackCount: result.calls, overflow: result.calls > 8, samples: result.samples)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            print("Terrain transform evidence: \(String(decoding: data, as: UTF8.self))")
            try #require(result.calls > 0 && result.calls <= 8)
        }
    }

    private func check(_ actual: CGImage, reference: CGImage, context: String) throws {
        try #require(actual.width == reference.width && actual.height == reference.height)
        let actualPixels = try pixels(actual)
        let expected = try pixels(reference)
        try #require(actualPixels.count == expected.count)
        let differentBytes = zip(actualPixels, expected).filter { $0 != $1 }.count
        #expect(differentBytes == 0, "\(context)")
        // Preserve the unchanged comparison before collecting diagnostic evidence.
        // Full buffers make pixel location and color/alpha differences inspectable.
        let differingPixels = stride(from: 0, to: actualPixels.count, by: 4).filter { offset in
            actualPixels[offset..<(offset + 4)] != expected[offset..<(offset + 4)]
        }
        let samples: [[String: Any]] = differingPixels.prefix(16).map { offset in
            ["x": (offset / 4) % actual.width, "y": (offset / 4) / actual.width,
             "actual": Array(actualPixels[offset..<(offset + 4)]),
             "expected": Array(expected[offset..<(offset + 4)])]
        }
        let identifier = context.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let record: [String: Any] = ["context": context, "identifier": identifier,
            "width": actual.width, "height": actual.height,
            "differentBytes": differentBytes, "differentPixels": differingPixels.count,
            "samples": samples]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("Terrain edge evidence: \(String(decoding: data, as: UTF8.self))")
        if differentBytes != 0 {
            Attachment.record(Array(data), named: identifier + "-comparison.json")
            Attachment.record(actualPixels, named: identifier + "-actual.rgba")
            Attachment.record(expected, named: identifier + "-expected.rgba")
            let actualPNG = try #require(MapImage.png(actual))
            let expectedPNG = try #require(MapImage.png(reference))
            Attachment.record(Array(actualPNG.data), named: identifier + "-actual.png")
            Attachment.record(Array(expectedPNG.data), named: identifier + "-expected.png")
        }
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        // ImageRenderer and the export context may expose different pixel formats.
        let context = try #require(MapImage.imageContext(width: image.width, height: image.height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try ItemPictureFixture.pixels(#require(context.makeImage())).bytes
    }
}
