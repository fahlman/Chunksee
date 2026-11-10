import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Fresh shipping layer owners run their producers against the already prepared world.
/// The on/off/on display sequence remains separate: showing retained images is not a load.
@MainActor
enum MapComparisonLoaders {
    /// Dark Spots uses the terrain renderer. Activate its real control before the first
    /// viewport request, then time terrain production with the prepared night rule.
    static func darkSpots(_ config: MapComparison.Configuration, resources: WorldResources,
                          to folder: URL) async throws -> [MapComparison.Weak] {
        let current = WorldSession(resources: resources, dimensionID: MapComparisonFixture.dimension)
        var owners = [MapComparison.Weak(current)]
        do {
            let map = try #require(current.map)
            owners.append(MapComparison.Weak(map))
            try MapComparison.hideOverlays(current)
            try MapComparison.apply(config.states[0], to: current)
            try MapComparisonAdapter.setOverlay("Dark Spots", shown: true, in: current)
            await MapComparison.settle(current)
            try #require(map.showsDarkSpots && map.nightLighting != nil)
            try await MapComparisonMeasures.load(config.views[0], in: current, to: folder)
            _ = try await MapComparisonState.capture(current, to: folder)
            current.close()
            await current.waitUntilClosed()
            return owners
        } catch {
            current.close()
            await current.waitUntilClosed()
            throw error
        }
    }

    static func heat(_ session: WorldSession, to folder: URL) async throws -> [MapComparison.Weak] {
        let reader = try #require(session.resources.readers[MapComparisonFixture.dimension])
        let expected = try #require(session.heatMap.visibleImages)
        let work = BackgroundWork()
        let start = MapComparisonMeasures.Stamp()
        let layer = MapComparisonAdapter.freshHeatMap(reader: reader, work: work)
        await layer.waitForReads()
        let end = MapComparisonMeasures.Stamp()
        let actual = layer.visibleImages ?? [:]
        layer.cancel()
        await layer.waitForReads()
        work.close()
        await work.waitUntilFinished()
        try record(actual, expected: expected, interval: start.until(end), to: folder)
        return [MapComparison.Weak(layer), MapComparison.Weak(work)]
    }

    static func slime(_ session: WorldSession, to folder: URL) async throws -> [MapComparison.Weak] {
        let seed = try #require(session.resources.details.seed)
        let regions = try #require(session.map).availableRegions
        let expected = session.slimeChunks.visibleImages
        let work = BackgroundWork()
        let start = MapComparisonMeasures.Stamp()
        let layer = MapComparisonAdapter.freshSlimeChunks(seed: seed, regions: regions, work: work)
        await layer.waitForImages()
        let end = MapComparisonMeasures.Stamp()
        let actual = layer.visibleImages
        layer.cancel()
        await layer.waitForImages()
        work.close()
        await work.waitUntilFinished()
        try record(actual, expected: expected, interval: start.until(end), to: folder)
        return [MapComparison.Weak(layer), MapComparison.Weak(work)]
    }

    private static func record(_ actual: [RegionPosition: CGImage], expected: [RegionPosition: CGImage],
                               interval: [String: Double], to folder: URL) throws {
        var artifacts: [String: Data] = [:], formats: [String: Any] = [:]
        // Preserve the measured interval even if the subsequent output comparison fails.
        try MapComparisonEvidence.write(["interval.json": MapComparisonEvidence.json([
            "interval": interval, "actualRegions": actual.count, "expectedRegions": expected.count,
            "scope": "fresh layer creation, first request, producer and publication; prepared world; no settings persistence",
        ])], to: folder)
        var matching = Set(actual.keys) == Set(expected.keys)
        for (region, image) in actual {
            let name = "r\(region.x).\(region.z)"
            let (bytes, format) = try MapComparisonEvidence.rawImage(image)
            artifacts[name + ".rgba"] = bytes
            formats[name] = format
            if let reference = expected[region] {
                let (referenceBytes, referenceFormat) = try MapComparisonEvidence.rawImage(reference)
                let matchingFormat = try MapComparisonEvidence.json(format) == MapComparisonEvidence.json(referenceFormat)
                matching = matching && bytes == referenceBytes && matchingFormat
            } else { matching = false }
        }
        artifacts["image-formats.json"] = try MapComparisonEvidence.json(formats)
        artifacts["comparison.json"] = try MapComparisonEvidence.json(["exact": matching])
        try MapComparisonEvidence.write(artifacts, to: folder)
        try #require(!actual.isEmpty && matching)
    }
}
