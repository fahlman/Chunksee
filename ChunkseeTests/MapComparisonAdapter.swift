import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

/// Endpoint API differences only: each branch calls its real visibility control.
@MainActor
enum MapComparisonAdapter {
    static func freshHeatMap(reader: RegionReader, work: BackgroundWork) -> HeatMapLayer {
        HeatMapLayer(reader: { reader }, isShown: { true }, work: work)
    }

    static func freshSlimeChunks(seed: Int64, regions: Set<RegionPosition>, work: BackgroundWork) -> SlimeChunkLayer {
        SlimeChunkLayer(dimensionID: MapComparisonFixture.dimension, seed: { seed },
                       isShown: { true }, regions: regions, work: work)
    }

    static func setOverlay(_ name: String, shown: Bool, in session: WorldSession) throws {
        switch name {
        case "Time Spent": session.visibility.showsTimeSpent = shown
        case "Slime Chunks": session.visibility.showsSlimeChunks = shown
        case "Dark Spots": session.setDarkSpots(shown)
        default: Issue.record("Unknown comparison overlay"); throw MapComparison.Failure.configuration
        }
    }
}

