import AppKit
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
        let fit = try #require(MapViewport.fitting(regions, in: CGSize(width: 1072, height: 1072)))
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
        let map = MapModel(definitions: { .unknown }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), world: .init(try World(contentsOf: root)), dimension: dimension, center: .zero, regionConcurrency: 1, chunkConcurrency: 1)
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
                    var content = MapContent(gameNames: .unavailable, terrain: map.drawingInput)
                    content.showsGrid = grid
                    var progress: [Int] = []
                    let actual = try await MapImage.export(plan: plan, regions: map.availableRegions, renderer: renderer,
                        content: content, portalStatus: { _ in nil }, colorScheme: appearance, locale: Locale(identifier: "en_US"),
                        progress: { finished, total in progress.append(finished); #expect(total == 2) })
                    let expected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil },
                        size: plan.size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                    let actualPixels = try pixels(actual), expectedPixels = try pixels(expected)
                    if actualPixels != expectedPixels {
                        Attachment.record(Array(actual.data), named: "export-actual-\(downsample)-\(appearance)-\(grid).png")
                        Attachment.record(Array(expected.data), named: "export-expected-\(downsample)-\(appearance)-\(grid).png")
                        let different = stride(from: 0, to: actualPixels.count, by: 4).filter {
                            actualPixels[$0..<$0 + 4] != expectedPixels[$0..<$0 + 4]
                        }
                        print("EXPORT_PIXEL_DIFFERENCE", downsample, appearance, grid, "count", different.count,
                              "samples", different.prefix(12).map { [String($0 / 4), String(describing: Array(actualPixels[$0..<$0 + 4])), String(describing: Array(expectedPixels[$0..<$0 + 4]))] })
                    }
                    #expect(actualPixels == expectedPixels)
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
                content: MapContent(gameNames: .unavailable), portalStatus: { _ in nil }, colorScheme: .light, locale: .current,
                progress: { finished, _ in #expect(finished == 0) }, readTile: { _, _ in await gate.read("tile") })
        }
        await gate.waitForRequest("tile")
        task.cancel()
        await gate.waitForCancellation("tile")
        let image = try #require(CGImage.rgba([100, 100, 100, 255], width: 1, height: 1))
        let cache = TileCache(directory: root.appendingPathComponent("export-tiles"))
        let renderer = RegionTileRenderer(dimension: dimension)
        let key = TileCache.Key(region: region, file: .init(size: 0, modified: 0), inputs: renderer.cacheInputs, biomeFiles: nil)
        let late = RegionTileRenderer.RenderedTile(key: .init(surface: key, preparation: renderer.preparation, chunk: nil), full: image, preview: image,
            cacheWrite: .init(cache: cache, key: key, surface: RegionTileRenderer.Canvas()))
        await gate.finish("tile", with: late)
        do {
            _ = try await task.value
            Issue.record("Canceled export published an image")
        } catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test func heightAndWaterDepthExportsShareCompleteKeysWhenTheyFit() async throws {
        let root = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:water"]) { x, y, _ in
                if x < 8 { return y <= 8 ? 1 : 0 }
                return y == 0 ? 1 : (y <= 8 ? 2 : 0)
            }
        ], dimensionSettings: ["minecraft:overworld": TestWorld.noiseDimension(
            type: .string("minecraft:overworld"), noise: .compound([
                "noise": .compound(["min_y": .int(-64), "height": .int(384)]), "sea_level": .int(4)
            ]))])
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(contentsOf: root), dimension = try #require(world.dimension("overworld"))
        let scale = try #require(MapHeightScale(settings: WorldDetails.read(world).dimensionSettings[dimension.id]))
        let map = MapModel(definitions: { .init(context: .unknown, heightScale: scale) }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), world: .init(try World(contentsOf: root)), dimension: dimension, center: .zero,
                           regionConcurrency: 1, chunkConcurrency: 1)
        defer { map.close() }
        for (side, showsKey) in [(105.0, false), (512.0, true)] {
            let plan = try MapExportPlan(bounds: CGRect(x: 0, y: 0, width: side, height: side), blocksPerPixel: 1)
            map.viewport = plan.viewport
            for style in [MapStyle.height, .waterDepth] {
                map.setStyle(style)
                for depth in [MapDepth(), MapDepth(y: 4, isSurface: false)] {
                    map.setDepth(depth)
                    map.requestTiles(visibleIn: plan.size, displayScale: 1)
                    await map.waitUntilIdle()
                    let content = MapContent(gameNames: .unavailable, terrain: map.drawingInput)
                    for appearance in [ColorScheme.light, .dark] {
                        let image = try await MapImage.export(plan: plan, regions: map.availableRegions,
                            renderer: (try requiredRenderer(map)), content: content, portalStatus: { _ in nil },
                            colorScheme: appearance, locale: Locale(identifier: "en_US"), progress: { _, _ in })
                        let view = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil },
                            size: plan.size, scale: 1, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                        for result in [image, view] {
                            let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
                            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                            #expect(decoded.width == Int(side) && decoded.height == Int(side))
                        }
                        let actual = try pixels(image)
                        #expect(try actual == pixels(view))
                        let withoutLegend = try #require(MapImage.renderWithoutLegend(map, content: content,
                            size: plan.size, colorScheme: appearance, locale: Locale(identifier: "en_US")))
                        // Tiny output keeps all its terrain; ordinary output still includes the key.
                        #expect(try (actual != pixels(withoutLegend)) == showsKey)
                        #expect(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] != 0 })
                    }
                }
            }
        }
        await map.waitForRenders()
    }

    enum ExportEnd: CaseIterable { case cancel, dismissSheet, replaceSheet, closeDocument }

    @Test(.timeLimit(.minutes(1)), arguments: ExportEnd.allCases)
    func endingAnExportDrainsItsWorkBeforeAnotherCanStart(_ ending: ExportEnd) async throws {
        let root = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(root), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let gate = AsyncReadGate<RegionTileRenderer.RenderedTile?>()
        let session = WorldSession(resources: resources, renderTile: { renderer, _ in
            #expect(renderer.cutawayY == 12)
            #expect(renderer.style == .waterDepth)
            #expect(renderer.blockFilter == MapBlockFilter(highlightedIDs: ["minecraft:stone"]))
            return await gate.read("tile")
        })
        await session.search.waitForIndex()
        session.map?.setDepth(MapDepth(y: 12, isSurface: false))
        session.map?.setStyle(.waterDepth)
        session.map?.setBlockFilter(MapBlockFilter(highlightedIDs: ["minecraft:stone"]))
        let export = session.imageExport
        export.options.area = .dimension
        session.presentSheet(.imageExport)
        #expect(export.canCreate)
        export.create(colorScheme: .light, locale: .current)
        await gate.waitForRequest("tile")
        #expect(export.isRunning && export.renderedDepth?.y == 12)
        session.map?.setDepth(MapDepth(y: 3, isSurface: false))
        session.map?.setStyle(.normal)
        session.map?.setBlockFilter(MapBlockFilter())
        #expect(export.renderedDepth?.y == 12)
        switch ending {
        case .cancel: export.cancel()
        case .dismissSheet: session.sheet = nil
        case .replaceSheet: session.presentSheet(.coordinates)
        case .closeDocument: session.close()
        }
        #expect(export.isRunning && export.isCancelling && !export.canCreate)
        export.create(colorScheme: .dark, locale: .current) // A draining export still owns its allocation.
        await gate.waitForCancellation("tile")
        await gate.finish("tile", with: nil)
        await export.waitUntilIdle()
        #expect(!export.isRunning && export.result == nil && export.preview == nil && export.error == nil)
        #expect(export.canCreate == (ending != .closeDocument))
        session.close()
        await session.waitUntilClosed()
    }

    @Test func aFinishedImageCopiesToAnExplicitBoardWithoutChangingTheDocumentsViewOrLayers() async throws {
        let root = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 }
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        await session.search.waitForIndex()
        let viewport = try #require(session.map?.viewport), grid = session.visibility.showsGrid
        let export = session.imageExport
        export.options.area = .dimension
        export.options.includesMarkers = false
        export.options.includesGrid = !grid
        export.create(colorScheme: .dark, locale: Locale(identifier: "en_US"))
        await export.waitUntilIdle()
        let image = try #require(export.result)
        #expect(export.preview != nil && export.error == nil && !export.isRunning)
        #expect(export.preparedPlan?.width == 512 && export.preparedPlan?.height == 512)
        #expect(session.map?.viewport == viewport && session.visibility.showsGrid == grid)
        let board = NSPasteboard(name: .init("ChunkseeTests-MapImage-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        image.copy(to: board)
        #expect(board.data(forType: .png) == image.data)
        #expect(try pixels(image).contains(255))
        export.options.blocksPerPixel = 2
        #expect(export.result == nil && export.preview == nil && export.preparedPlan == nil)
        session.close()
        await session.waitUntilClosed()
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
