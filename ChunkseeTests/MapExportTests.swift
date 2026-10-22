import ChunkseeKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapExportTests {
    @Test func wholeDimensionAndFitWorldShareTheSavedRegionExtent() throws {
        let regions: Set<RegionPosition> = [.init(x: -2, z: -1), .init(x: 1, z: 2)]
        let bounds = try #require(MapViewport.bounds(of: regions))
        #expect(bounds == CGRect(x: -1024, y: -512, width: 2048, height: 2048))
        let fit = try #require(MapViewport.fitting(regions, in: CGSize(width: 1048, height: 1048)))
        #expect(fit.center == CGPoint(x: bounds.midX, y: bounds.midY) && fit.scale == 0.5)
        let image = try MapExportPlan(bounds: bounds, blocksPerPixel: 2)
        #expect(image.width == 1024 && image.height == 1024)
        #expect(image.viewport.blockPoint(at: .zero, in: image.size) == bounds.origin)
        #expect(MapViewport.bounds(of: []) == nil)
    }

    @Test func visibleAndMeasuredAreasKeepTheirOriginsAndIncludeBothEndpointBlocks() throws {
        let viewport = MapViewport(center: CGPoint(x: -10.25, y: 20.75), scale: 2)
        let bounds = try #require(MapExportPlan.visibleBounds(viewport: viewport, size: CGSize(width: 101, height: 61)))
        #expect(bounds == CGRect(x: -35.5, y: 5.5, width: 50.5, height: 30.5))
        let image = try MapExportPlan(bounds: bounds, blocksPerPixel: 2)
        #expect(image.width == 26 && image.height == 16)
        #expect(image.viewport.blockPoint(at: .zero, in: image.size) == bounds.origin)
        var ruler = MapRuler()
        ruler.isEnabled = true
        ruler.mark(CGPoint(x: -8.7, y: 4))
        #expect(MapExportPlan.measuredBounds(ruler) == nil)
        ruler.mark(CGPoint(x: -3.1, y: 4))
        #expect(MapExportPlan.measuredBounds(ruler) == CGRect(x: -9, y: 4, width: 6, height: 1))
        ruler.clear()
        ruler.mark(CGPoint(x: -2, y: -3))
        ruler.mark(CGPoint(x: -2, y: -3))
        #expect(MapExportPlan.measuredBounds(ruler) == CGRect(x: -2, y: -3, width: 1, height: 1))
    }

    @Test func oversizedAndInvalidImagesAreRejectedBeforeAnyAllocation() throws {
        let largest = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 4096, height: 4096), blocksPerPixel: 1)
        #expect(largest.uncompressedBytes == 64 * 1024 * 1024)
        #expect(throws: MapExportPlan.Failure.tooLarge) {
            try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 4096, height: 4097), blocksPerPixel: 1)
        }
        #expect(throws: MapExportPlan.Failure.tooLarge) {
            try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 16385, height: 1), blocksPerPixel: 1)
        }
        let distant = CGRect(x: -30_000_000, y: -30_000_000, width: 60_000_000, height: 60_000_000)
        #expect(throws: MapExportPlan.Failure.tooLarge) { try MapExportPlan(bounds: distant, blocksPerPixel: 1) }
        let overview = try MapExportPlan(bounds: distant, blocksPerPixel: 16384)
        #expect(overview.width == 3663 && overview.height == 3663)
        for invalid in [Double.nan, .infinity, -.infinity, -.greatestFiniteMagnitude, 0] {
            #expect(throws: MapExportPlan.Failure.invalidArea) {
                try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: invalid, height: 1), blocksPerPixel: 1)
            }
        }
        for invalid in [-1, 0, 3, Int.max] {
            #expect(throws: MapExportPlan.Failure.invalidArea) {
                try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), blocksPerPixel: invalid)
            }
        }
        #expect(throws: MapExportPlan.Failure.tooLarge) {
            try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: Double.greatestFiniteMagnitude, height: 1), blocksPerPixel: 1)
        }
    }

    @Test func streamingTilesMatchesTheExistingMapImageInBothAppearances() async throws {
        let root = try TestWorld.make(chunks: [
            TestWorld.chunk(x: -1, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:grass_block"]) { _, y, _ in y == 10 ? 1 : 0 }
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero, regionConcurrency: 1, chunkConcurrency: 1)
        defer { map.close() }
        let renderer = RegionTileRenderer(dimension: dimension, chunkConcurrency: 1)
        let bounds = CGRect(x: -24, y: -8, width: 48, height: 32)
        for downsample in [1, 2] {
            let plan = try MapExportPlan(bounds: bounds, blocksPerPixel: downsample)
            map.viewport = plan.viewport
            map.requestTiles(visibleIn: plan.size, displayScale: 1)
            await map.waitUntilIdle()
            for appearance in [ColorScheme.light, .dark] {
                for grid in [false, true] {
                    var content = MapContent()
                    content.showsGrid = grid
                    var progress: [Int] = []
                    let actual = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: renderer,
                        content: content, portalStatus: { _ in nil }, colorScheme: appearance, locale: Locale(identifier: "en_US"),
                        progress: { finished, total in progress.append(finished); #expect(total == 2) })
                    let expected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil },
                        size: plan.size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                    #expect(try pixels(actual) == pixels(expected))
                    #expect(progress == [0, 1, 2])
                }
            }
        }
        await map.waitForRenders()
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDiscardsALateTileBeforeDrawingOrCachingIt() async throws {
        let root = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: 16, height: 16), blocksPerPixel: 1)
        let gate = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let region = RegionPosition(x: 0, z: 0)
        let task = Task {
            try await MapImage.export(plan: plan, regions: [region], renderer: RegionTileRenderer(dimension: dimension),
                content: MapContent(), portalStatus: { _ in nil }, colorScheme: .light, locale: .current,
                progress: { finished, _ in #expect(finished == 0) }, readTile: { _, _ in await gate.read("tile") })
        }
        await gate.waitForRequest("tile")
        task.cancel()
        await gate.waitForCancellation("tile")
        let image = try #require(CGImage.rgba([100, 100, 100, 255], width: 1, height: 1))
        let cache = TileCache(directory: root.appendingPathComponent("export-tiles"))
        let key = TileCache.Key(region: region, fileSize: 0, modified: 0)
        let late = RegionTileRenderer.RenderedTile(full: image, preview: image,
            cacheWrite: .init(cache: cache, key: key, pixels: [100, 100, 100, 255]))
        await gate.finish("tile", with: late)
        do {
            _ = try await task.value
            Issue.record("Canceled export published an image")
        } catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    private func pixels(_ image: MapImage) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        }
        return bytes
    }
}
