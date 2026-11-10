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
            let result = try await freshState(state, config: config, resources: session.resources, output: output)
            try #require(result.owners.allSatisfy { $0.value == nil })
            count += result.count
            coverage.merge(result.coverage) { _, new in new }
            if result.detailed { detailedStyles.insert(state.style.rawValue) }
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

    struct StateResult {
        let count: Int
        let detailed: Bool
        let coverage: [String: [String: Bool]]
        let owners: [Weak]
    }

    /// A fresh document lets both endpoints finish all settings changes before requesting
    /// terrain. The anchor document keeps the same prepared world and real disk cache alive.
    static func freshState(_ state: State, config: Configuration, resources: WorldResources,
                           output: URL) async throws -> StateResult {
        let current = WorldSession(resources: resources, dimensionID: MapComparisonFixture.dimension)
        var owners = [Weak(current), Weak(current.heatMap), Weak(current.slimeChunks)]
        var count = 0, shadow = false, lighting = false, detailed = false
        var coverage: [String: [String: Bool]] = [:]
        do {
            owners.append(Weak(try #require(current.map)))
            try hideOverlays(current)
            try apply(state, to: current)
            await settle(current)
            for view in config.views {
                let folder = output.appendingPathComponent("states/\(state.id)/\(view.id)")
                try await MapComparisonMeasures.load(view, in: current, to: folder)
                let actual = try await MapComparisonState.capture(current, to: folder)
                coverage[state.id + "/" + view.id] = actual
                count += try await MapComparisonEvidence.pictures(current, export: view.id == "boundary", to: folder)
                if state.surface && (!state.filter.enabled || (state.filter.hidden.isEmpty && state.filter.highlighted.isEmpty)) {
                    try #require(actual["waterBlock"] == true && actual["waterDepth8"] == true)
                }
                if state.style == .height {
                    try #require(actual["detail"] == false && actual["savedLighting"] == false && actual["nonemptyShadow"] == false)
                }
                shadow = shadow || actual["nonemptyShadow"] == true
                lighting = lighting || actual["savedLighting"] == true
                detailed = detailed || (view.scale == 8 && actual["detail"] == true)
            }
            if state.id == "normal-saved-shadows" || state.id == "water-depth-saved-shadows" {
                try requireCoverage(shadow && lighting, "Missing saved lighting or nonempty shadows for \(state.id)")
            }
            current.close()
            await current.waitUntilClosed()
            return StateResult(count: count, detailed: detailed, coverage: coverage, owners: owners)
        } catch {
            current.close()
            await current.waitUntilClosed()
            throw error
        }
    }

    static func overlays(_ config: Configuration, session: WorldSession, output: URL) async throws -> Int {
        try hideOverlays(session)
        try apply(config.states[0], to: session)
        var count = 0
        for name in ["Time Spent", "Slime Chunks", "Dark Spots"] {
            for (step, shown) in [true, false, true].enumerated() {
                let folder = output.appendingPathComponent("overlays/\(name.replacingOccurrences(of: " ", with: "-"))-\(step)")
                if step == 0 && name == "Dark Spots" {
                    let owners = try await MapComparisonLoaders.darkSpots(config, resources: session.resources,
                        to: folder.appendingPathComponent("fresh-loader"))
                    try #require(owners.allSatisfy { $0.value == nil })
                }
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
                _ = try await MapComparisonState.capture(session, to: folder)
                if step == 0 && name != "Dark Spots" {
                    let loaderFolder = folder.appendingPathComponent("fresh-loader")
                    let owners: [Weak]
                    if name == "Time Spent" {
                        owners = try await MapComparisonLoaders.heat(session, to: loaderFolder)
                    } else {
                        owners = try await MapComparisonLoaders.slime(session, to: loaderFolder)
                    }
                    try #require(owners.allSatisfy { $0.value == nil })
                }
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

}
