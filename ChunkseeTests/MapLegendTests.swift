import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapLegendTests {
    @Test func exportedKeysFollowShownOverlaysEvenBeforeTheirImagesArrive() async throws {
        let url = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 },
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try Fixtures.writeGzippedNBT(.compound([
            "DataVersion": .int(Int32(SaveVersion.java26_3)),
            "data": .compound(["size": .double(64), "center_x": .double(10_000), "center_z": .double(10_000)]),
        ]), to: url.appendingPathComponent("dimensions/minecraft/overworld/data/minecraft/world_border.dat"))
        let world = try World(contentsOf: url)
        let dimension = try #require(world.dimension("minecraft:overworld"))
        let border = try #require(try world.worldBorder(of: dimension))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8),
                           regionConcurrency: 1, chunkConcurrency: 1)
        let size = CGSize(width: 480, height: 320)
        map.requestTiles(visibleIn: size, displayScale: 1)
        await map.waitUntilIdle()
        for appearance in [ColorScheme.light, .dark] {
            for (slime, boundary) in [(false, false), (true, false), (false, true), (true, true)] {
                var content = MapContent()
                content.slimeSeed = slime ? 42 : nil
                content.border = boundary ? border : nil
                let image = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil },
                    size: size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                Attachment.record(Array(image.data), named: "legend-\(appearance)-slime-\(slime)-border-\(boundary).png")
                let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                var pixels = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
                let rendered = pixels.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(data: bytes.baseAddress, width: decoded.width, height: decoded.height,
                        bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
                    return true
                }
                #expect(rendered)
                var green = false, red = false
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    green = green || (g > 40 && g - r > 20 && g - b > 20)
                    red = red || (r > 100 && r - g > 30 && r - b > 30)
                }
                // The gray terrain has no tint, the border is offscreen, and the masks have not
                // arrived. Only the legend can supply its shown overlay's color.
                #expect(green == slime && red == boundary)
            }
        }
        map.close()
        await map.waitForRenders()
    }
}
