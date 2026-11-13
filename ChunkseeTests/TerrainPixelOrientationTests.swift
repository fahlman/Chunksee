import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) @MainActor struct TerrainPixelOrientationTests {
    @Test func crispTerrainPreservesImageOrientationOpacityAndLighting() throws {
        // Four different corners catch a vertical flip that uniform seam images cannot.
        let image = try #require(CGImage.rgba([
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255
        ], width: 2, height: 2))
        let normals = try #require(CGImage.rgba([
            37, 218, 128, 255, 218, 218, 128, 255,
            128, 255, 128, 255, 0, 0, 0, 255
        ], width: 2, height: 2, colorSpace: CGColorSpace.linearSRGB))
        let time = try JSONDecoder().decode(DimensionTime.self, from: Data(#"{"has_skylight":true}"#.utf8))
        let saved = try #require(SkyLighting(sunAngle: 300, moonAngle: 0, skyLightFactor: 0.24,
                                             skyLightColor: SIMD3(0.48, 0.48, 1), moonPhase: .fullMoon))
        let lighting = try #require(MapLighting(saved: saved, time: time))
        let size = CGSize(width: 32, height: 32), region = RegionPosition(x: 0, z: 0)
        let viewport = MapViewport(center: CGPoint(x: 256, y: 256), scale: 1)
        let rect = try #require(viewport.viewRect(for: region, in: size))
        for scale: CGFloat in [1, 2] {
            var unlitReference: Data?
            for mode in ["terrain", "shadow", "lit"] {
                let name = "terrain-orientation-display\(scale)-\(mode)"
                let reference = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    var layer = context
                    if mode == "shadow" { layer.opacity = 0.22 }
                    if mode == "lit" {
                        layer.addFilter(.colorShader(lighting.shader(normals: normals, rect: rect,
                            protectsWater: false, increasedContrast: false)), options: .linearColor)
                    }
                    layer.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
                }
                let actual = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    if mode == "shadow" {
                        MapView.drawShadow(image, rect: rect, interpolation: .none,
                                           increasedContrast: false, in: context)
                    } else {
                        MapView.drawTerrainImage(MapTileImage(image, normals: normals), rect: rect, interpolation: .none,
                            lighting: mode == "lit" ? lighting : nil, protectsWater: false,
                            increasedContrast: false, in: context)
                    }
                }
                func render<V: View>(_ canvas: V) throws -> CGImage {
                    let renderer = ImageRenderer(content: canvas.frame(width: size.width, height: size.height)
                        .environment(\.displayScale, scale))
                    renderer.scale = scale
                    return try #require(renderer.cgImage)
                }
                func pixels(_ image: CGImage) throws -> Data {
                    let context = try #require(MapImage.imageContext(width: image.width, height: image.height))
                    context.interpolationQuality = .none
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    let normalized = try #require(context.makeImage())
                    return Data(try ItemPictureFixture.pixels(normalized).bytes)
                }
                let expected = try pixels(render(reference))
                if mode == "terrain" { unlitReference = expected }
                if mode == "lit" {
                    let unlit = try #require(unlitReference)
                    try #require(expected != unlit)
                }
                let screen = try pixels(render(actual))
                let destination = try #require(MapImage.imageContext(width: Int(size.width * scale),
                                                                    height: Int(size.height * scale)))
                if mode == "shadow" {
                    try #require(MapImage.drawImageLayer(actual, size: size, scale: scale, into: destination))
                } else {
                    let input = MapDrawingInput(presentation: MapPresentation(), heightScale: nil,
                                                savedLighting: mode == "lit" ? lighting : nil)
                    try #require(MapImage.drawTerrainLayer(MapTileImage(image, normals: normals), region: region,
                        viewport: viewport, size: size, scale: scale, input: input,
                        contrast: .standard, into: destination))
                }
                let exported = try pixels(#require(destination.makeImage()))
                #expect(screen == expected, "\(name): screen orientation or opacity changed")
                #expect(exported == expected, "\(name): exported orientation or opacity changed")
            }
        }
    }
}
