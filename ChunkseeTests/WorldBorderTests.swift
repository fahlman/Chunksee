import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct WorldBorderTests {
    private func world() throws -> URL {
        let url = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 },
        ])
        for (id, size) in [("overworld", 64.0), ("the_nether", 32.0), ("the_end", WorldBorder.defaultSize)] {
            let folder = url.appendingPathComponent("dimensions/minecraft/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("region"), withIntermediateDirectories: true)
            try Fixtures.writeGzippedNBT(.compound([
                "DataVersion": .int(Int32(SaveVersion.java26_3)),
                "data": .compound(["size": .double(size), "center_x": .double(8), "center_z": .double(8)]),
            ]), to: folder.appendingPathComponent("data/minecraft/world_border.dat"))
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dimensions/example/missing/region"),
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func visibilityKeepsBorderDetailsAndRestoresEachDimensionIndependently() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make(), id = UUID()
        // An existing dimension with no border choice keeps the previously always-shown border.
        WorldSettings(id: id, defaults: defaults).saveLayers([.showsGrid: true], for: "minecraft:overworld")
        func open() async throws -> WorldResources {
            WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                           savedSearches: SavedSearches(defaults: defaults),
                           settings: WorldSettings(id: id, defaults: defaults), cacheRoot: nil,
                           watchWorld: { _, _ in nil })
        }
        let resources = try await open()
        defer { resources.close() }
        let overworld = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let nether = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        let end = WorldSession(resources: resources, dimensionID: "minecraft:the_end")
        let missing = WorldSession(resources: resources, dimensionID: "example:missing")
        #expect(overworld.visibility.showsWorldBorder && nether.visibility.showsWorldBorder)
        #expect(overworld.presentation.limitedWorldBorder?.size == 64)
        #expect(nether.presentation.limitedWorldBorder?.size == 32)
        #expect(end.details.borders["minecraft:the_end"]?.size == WorldBorder.defaultSize)
        #expect(end.presentation.limitedWorldBorder == nil && MapContent(session: end).border == nil)
        #expect(missing.presentation.limitedWorldBorder == nil && MapContent(session: missing).border == nil)
        #expect(MapContent(session: overworld).border?.size == 64)
        overworld.visibility.showsWorldBorder = false
        #expect(MapContent(session: overworld).border == nil && MapContent(session: nether).border?.size == 32)
        #expect(overworld.details.borders["minecraft:overworld"]?.size == 64)
        #expect(overworld.presentation.limitedWorldBorder != nil)
        resources.close()
        await resources.waitUntilClosed()
        #expect(overworld.presentation.limitedWorldBorder == nil && MapContent(session: overworld).border == nil)

        let reopened = try await open()
        defer { reopened.close() }
        let restored = WorldSession(resources: reopened, dimensionID: "minecraft:overworld")
        let restoredNether = WorldSession(resources: reopened, dimensionID: "minecraft:the_nether")
        #expect(!restored.visibility.showsWorldBorder && restoredNether.visibility.showsWorldBorder)
        #expect(MapContent(session: restored).border == nil && MapContent(session: restoredNether).border?.size == 32)
        #expect(restored.visibility.showsGrid)
        restored.visibility.showsWorldBorder = true
        #expect(MapContent(session: restored).border?.size == 64)
        let otherWorld = LayerVisibility(settings: WorldSettings(id: UUID(), defaults: defaults), dimension: "minecraft:overworld")
        #expect(otherWorld.showsWorldBorder)
        #expect(defaults.object(forKey: "showsWorldBorder") == nil)
        reopened.close()
        await reopened.waitUntilClosed()
    }

    @Test func exportedBorderFollowsTheDocumentVisibilityInBothAppearances() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
                                           savedSearches: SavedSearches(defaults: defaults), defaults: defaults,
                                           cacheRoot: nil, watchWorld: { _, _ in nil })
        defer { resources.close() }
        let session = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let map = try #require(session.map), size = CGSize(width: 320, height: 240)
        map.viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 2)
        map.requestTiles(visibleIn: size, displayScale: 1)
        await map.waitUntilIdle()
        for appearance in [ColorScheme.light, .dark] {
            for shown in [true, false] {
                session.visibility.showsWorldBorder = shown
                let image = try #require(MapImage.render(map, content: MapContent(session: session), portalStatus: { _ in nil },
                    size: size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                Attachment.record(Array(image.data), named: "world-border-\(appearance)-\(shown).png")
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
                let redPixels = stride(from: 0, to: pixels.count, by: 4).filter { offset in
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    return r > 150 && r > g * 2 && r > b * 2
                }.count
                // Gray stone supplies no red. This exercises the document-to-export path.
                #expect(shown ? redPixels > 100 : redPixels == 0)
            }
        }
        resources.close()
        await resources.waitUntilClosed()
    }
}
