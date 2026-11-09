import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

extension MapComparison {
    static func states(_ config: Configuration, session: WorldSession, output: URL) async throws -> Int {
        try hideOverlays(session)
        await settle(session)
        var count = 0, detailedStyles: Set<String> = []
        var coverage: [String: [String: Bool]] = [:]
        for state in config.states {
            try apply(state, to: session)
            var shadow = false, lighting = false
            for view in config.views {
                try await show(view, in: session)
                let folder = output.appendingPathComponent("states/\(state.id)/\(view.id)")
                let actual = try await MapComparisonState.capture(session, to: folder)
                coverage[state.id + "/" + view.id] = actual
                count += try await MapComparisonEvidence.pictures(session, export: view.id == "boundary", to: folder)
                if state.surface && (!state.filter.enabled || (state.filter.hidden.isEmpty && state.filter.highlighted.isEmpty)) {
                    try #require(actual["waterBlock"] == true && actual["waterDepth8"] == true)
                }
                if state.style == .height {
                    try #require(actual["detail"] == false && actual["savedLighting"] == false && actual["nonemptyShadow"] == false)
                }
                shadow = shadow || actual["nonemptyShadow"] == true
                lighting = lighting || actual["savedLighting"] == true
                if view.scale == 8 && actual["detail"] == true { detailedStyles.insert(state.style.rawValue) }
            }
            if state.id == "normal-saved-shadows" || state.id == "water-depth-saved-shadows" {
                try requireCoverage(shadow && lighting, "Missing saved lighting or nonempty shadows for \(state.id)")
            }
        }
        try MapComparisonEvidence.write(["state-coverage.json": MapComparisonEvidence.json(coverage)], to: output)
        if config.artwork {
            try requireCoverage(detailedStyles.contains("normal") && detailedStyles.contains("waterDepth"),
                                "Artwork-on Normal and Water Depth must both include close-up detail")
        } else {
            try #require(detailedStyles.isEmpty)
        }
        try #require(count == 100)
        return count
    }

    static func overlays(_ config: Configuration, session: WorldSession, output: URL) async throws -> Int {
        try hideOverlays(session)
        try apply(config.states[0], to: session)
        var count = 0
        for name in ["Time Spent", "Slime Chunks", "Dark Spots"] {
            for (step, shown) in [true, false, true].enumerated() {
                try MapComparisonAdapter.setOverlay(name, shown: shown, in: session)
                await settle(session)
                try await show(config.views[0], in: session)
                let map = try #require(session.map)
                switch name {
                case "Time Spent":
                    try #require(session.heatMap.isShown == shown)
                    try #require(shown ? !(session.heatMap.visibleImages ?? [:]).isEmpty : session.heatMap.visibleImages == nil)
                case "Slime Chunks":
                    try #require(session.slimeChunks.isShown == shown)
                    try #require(shown ? !session.slimeChunks.visibleImages.isEmpty : session.slimeChunks.visibleImages.isEmpty)
                default:
                    try #require(map.showsDarkSpots == shown)
                    let renderer = try requiredRenderer(map)
                    try #require((renderer.cacheInputs.nightLight != nil) == shown)
                    if shown { try #require(map.nightLighting != nil && !map.tiles.isEmpty) }
                }
                let folder = output.appendingPathComponent("overlays/\(name.replacingOccurrences(of: " ", with: "-"))-\(step)")
                _ = try await MapComparisonState.capture(session, to: folder)
                count += try await MapComparisonEvidence.pictures(session, export: false, to: folder)
            }
            try MapComparisonAdapter.setOverlay(name, shown: false, in: session)
            await settle(session)
        }
        try #require(count == 36)
        return count
    }

    static func definitions(_ config: Configuration, session: WorldSession, output: URL) async throws -> Int {
        try hideOverlays(session)
        let height = try #require(config.states.first { $0.id == "height-surface" })
        try apply(height, to: session)
        var count = 0
        for phase in 0..<3 {
            if phase == 1 {
                session.names.minecraft.forget()
                await session.names.minecraft.waitUntilIdle()
            } else if phase == 2 {
                session.names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
                await session.names.minecraft.waitUntilIdle()
            }
            await settle(session)
            try await show(config.views[0], in: session)
            let map = try #require(session.map)
            try #require(map.chosenStyle == .height)
            let expectedStyle: MapStyle = map.heightScale == nil ? .normal : .height
            try #require(map.style == expectedStyle)
            try #require((session.resources.mapGameResources.data != nil) == (phase != 1))
            try #require(session.names.minecraft.usesGameArtwork == config.artwork)
            let folder = output.appendingPathComponent("definitions/phase-\(phase)")
            _ = try await MapComparisonState.capture(session, to: folder)
            count += try await MapComparisonEvidence.pictures(session, export: false, to: folder)
        }
        try #require(count == 12)
        return count
    }

    static func canonical(_ config: Configuration, session: WorldSession, output: URL) async throws {
        try hideOverlays(session)
        await settle(session)
        let points = [CGPoint(x: -256, y: -256), CGPoint(x: 99, y: -68), CGPoint(x: 2279, y: -817)]
        let regions = [RegionPosition(x: -1, z: -1), RegionPosition(x: 0, z: -1), RegionPosition(x: 4, z: -2)]
        var tileNames: Set<String> = [], detailNames: Set<String> = []
        for id in ["normal-surface", "height-surface", "water-depth-surface"] {
            let state = try #require(config.states.first { $0.id == id })
            try apply(state, to: session)
            for (index, point) in points.enumerated() {
                let view = View(id: "canonical", center: [Double(point.x), Double(point.y)],
                    scale: config.artwork ? 8 : 1, size: [512, 384])
                try await show(view, in: session)
                let map = try #require(session.map), region = regions[index]
                let renderer = try requiredRenderer(map)
                let tile = try #require(map.tiles[region])
                try #require(renderer.accepts(tile.key))
                let eligible = config.artwork && state.style != .height
                let folder = output.appendingPathComponent("canonical/\(state.style.rawValue)/r\(region.x).\(region.z)")
                _ = try await MapComparisonState.capture(session, to: folder)
                await map.waitForRenders()
                try #require(map.unfinishedCacheWrites == 0)
                let raw = try await cachedSurface(renderer, region: region, detail: eligible)
                try #require(raw.key == tile.key.surface)
                try #require(tileNames.insert(raw.tileName).inserted)
                if let name = raw.detailName { try #require(detailNames.insert(name).inserted) }
                try MapComparisonEvidence.write(raw.artifacts, to: folder)
            }
        }
        try #require(tileNames.count == 9 && detailNames.count == (config.artwork ? 6 : 0))
        let events = MapComparisonTrace.snapshot()
        let hitTiles = Set(events.filter { $0.kind == .tileHit }.compactMap { $0.key?.fileName })
        let missTiles = Set(events.filter { $0.kind == .tileMiss }.compactMap { $0.key?.fileName })
        let hitDetails = Set(events.filter { $0.kind == .detailHit }.compactMap { $0.key?.detailFileName })
        try MapComparisonEvidence.write(["canonical-coverage.json": MapComparisonEvidence.json([
            "tileNames": tileNames.sorted(), "detailNames": detailNames.sorted(),
            "actualTileHits": hitTiles.sorted(), "actualTileMisses": missTiles.sorted(),
            "actualDetailHits": hitDetails.sorted(),
        ])], to: output)
        if config.mode == "reuse" {
            try #require(tileNames.isSubset(of: hitTiles) && detailNames.isSubset(of: hitDetails))
        } else {
            try #require(tileNames.isSubset(of: missTiles))
        }
    }

    nonisolated struct CachedSurface: Sendable {
        let key: TileCache.Key
        let tileName: String
        let detailName: String?
        let artifacts: [String: Data]
    }

    /// Read the stored values through the shipping cache decoder, without reconstructing terrain.
    /// This extra evidence read is separate from the instrumented real renderer cache-hit path.
    @concurrent static func cachedSurface(_ renderer: RegionTileRenderer, region: RegionPosition,
                                         detail: Bool) async throws -> CachedSurface {
        let cache = try #require(renderer.cache), key = try #require(renderer.cacheKey(for: region))
        let name = try #require(key.fileName)
        let surface = try #require(cache.load(key))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var artifacts = [
            "stored-key.json": try encoder.encode(key),
            "stored-colors.rgba": Data(surface.pixels),
            "stored-heights.i32le": surface.heights.map(\.littleEndian).withUnsafeBytes { Data($0) },
            "stored-water.u8": Data(surface.isWater.map { $0 ? UInt8(1) : 0 }),
        ]
        if let light = surface.nightLight { artifacts["stored-night-light.u8"] = Data(light) }
        var detailName: String?
        if detail {
            detailName = try #require(key.detailFileName)
            let sidecar = try #require(cache.loadDetail(key))
            artifacts["stored-detail.plist"] = try #require(sidecar.detail.encoded())
            artifacts["detail-heights.i32le"] = sidecar.heights.map(\.littleEndian).withUnsafeBytes { Data($0) }
            if let light = sidecar.nightLight { artifacts["detail-night-light.u8"] = Data(light) }
            try #require(sidecar.heights == surface.heights && sidecar.nightLight == surface.nightLight)
        } else {
            let path = cache.directory.appendingPathComponent(try #require(key.detailFileName))
            try #require(!FileManager.default.fileExists(atPath: path.path))
        }
        return CachedSurface(key: key, tileName: name, detailName: detailName, artifacts: artifacts)
    }
}

