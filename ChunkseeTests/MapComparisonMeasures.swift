import Darwin
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Evidence clocks stay in the test bundle. No per-tile recorder runs in the product.
@MainActor
enum MapComparisonMeasures {
    nonisolated struct Stamp {
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = Self.cpuSeconds()

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }

        func until(_ end: Stamp) -> [String: Double] {
            ["wallSeconds": Double(end.wall - wall) / 1e9,
             "processCPUSeconds": end.cpu - cpu]
        }
    }

    final class Draws {
        var intervals: [[String: Double]] = []
    }

    /// The session has its final choices before this interval. No settings setter is timed.
    /// A new session starts each state's boundary view with no retained terrain; the close-up
    /// then uses that same session and the shipping cache, detail and shadow policies.
    static func load(_ view: MapComparison.View, in session: WorldSession, to folder: URL) async throws {
        let map = try #require(session.map)
        map.viewport = MapViewport(center: CGPoint(x: view.center[0], y: view.center[1]), scale: view.scale)
        // Viewport changes can start coordinate reads. They are setup for this terrain interval.
        await MapComparison.settle(session)
        let before = ["tiles": map.tiles.count, "previews": map.previews.count,
                      "detail": map.detailImages.count, "shadows": map.shadowImages.count]
        if view.id == "boundary" {
            try #require(before.values.allSatisfy { $0 == 0 })
        }
        let renderer = try requiredRenderer(map)
        let directory = try #require(renderer.cache).directory
        let imagesBefore = try cacheKeys(map)
        let cacheBefore = try await MapComparisonFiles.cacheInventory(directory)
        let start = Stamp()
        map.requestTiles(visibleIn: MapComparisonEvidence.size, displayScale: 1)
        await map.waitUntilIdle()
        await map.waitForRenders()
        let end = Stamp()
        let after = ["tiles": map.tiles.count, "previews": map.previews.count,
                     "detail": map.detailImages.count, "shadows": map.shadowImages.count]
        let measurement: [String: Any] = [
            "interval": start.until(end), "before": before, "after": after,
            "view": view.id, "drained": !map.isLoading && map.unfinishedCacheWrites == 0,
            "scope": "requestTiles through terrain/detail/shadow/cache-write drain; world and settings setup excluded",
        ]
        do {
            let cacheAfter = try await MapComparisonFiles.cacheInventory(directory)
            let imagesAfter = try cacheKeys(map)
            try MapComparisonEvidence.write([
                "terrain-load-interval.json": MapComparisonEvidence.json(measurement),
                "terrain-cache-before.json": MapComparisonEvidence.json([
                    "files": try MapComparisonEvidence.object(cacheBefore), "images": imagesBefore,
                ]),
                "terrain-cache-after.json": MapComparisonEvidence.json([
                    "files": try MapComparisonEvidence.object(cacheAfter), "images": imagesAfter,
                ]),
            ], to: folder)
        } catch {
            // A metadata/capture failure must not discard a completed product interval.
            try? MapComparisonEvidence.write([
                "terrain-load-interval.json": MapComparisonEvidence.json(measurement),
            ], to: folder)
            throw error
        }
        try #require(!map.isLoading && map.unfinishedCacheWrites == 0)
    }

    /// Retained image identities distinguish memory reuse from disk reads. File names come
    /// from the product's typed keys, including sidecars; the test does not rebuild key rules.
    private static func cacheKeys(_ map: MapModel) throws -> [String: Any] {
        func record(_ image: CachedMapImage) throws -> [String: Any] {
            let key = image.key.surface
            return ["key": try MapComparisonEvidence.object(key),
                    "fileName": try #require(key.fileName),
                    "detailFileName": try #require(key.detailFileName), "prefix": key.prefix]
        }
        var tiles: [String: Any] = [:], previews: [String: Any] = [:], detail: [String: Any] = [:]
        for (region, image) in map.tiles { tiles["r\(region.x).\(region.z)"] = try record(image) }
        for (region, image) in map.previews { previews["r\(region.x).\(region.z)"] = try record(image) }
        for (chunk, image) in map.detailImages { detail["\(chunk.x).\(chunk.z)"] = try record(image) }
        return ["tiles": tiles, "previews": previews, "detail": detail]
    }
}
