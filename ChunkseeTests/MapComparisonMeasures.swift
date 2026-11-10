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
        let start = Stamp()
        map.requestTiles(visibleIn: MapComparisonEvidence.size, displayScale: 1)
        await map.waitUntilIdle()
        await map.waitForRenders()
        let end = Stamp()
        let after = ["tiles": map.tiles.count, "previews": map.previews.count,
                     "detail": map.detailImages.count, "shadows": map.shadowImages.count]
        try MapComparisonEvidence.write(["terrain-load-interval.json": MapComparisonEvidence.json([
            "interval": start.until(end), "before": before, "after": after,
            "view": view.id, "drained": !map.isLoading && map.unfinishedCacheWrites == 0,
            "scope": "requestTiles through terrain/detail/shadow/cache-write drain; world and settings setup excluded",
        ])], to: folder)
        try #require(!map.isLoading && map.unfinishedCacheWrites == 0)
    }
}
