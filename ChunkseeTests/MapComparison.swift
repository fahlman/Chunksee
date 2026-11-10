import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Evidence-only correctness and cache proof. There is deliberately no timing mode.
@Suite(.isolatedStores)
@MainActor
struct MapComparison {
    nonisolated struct Filter: Decodable, Sendable {
        let enabled: Bool
        let hidden: [String]
        let highlighted: [String]
    }
    nonisolated struct State: Decodable, Sendable {
        let id: String
        let style: MapStyle
        let surface: Bool
        let y: Int
        let lighting: MapLightingMode
        let shadows: Bool
        let blending: Bool
        let filter: Filter

        private enum CodingKeys: String, CodingKey {
            case id, style, surface, y, lighting, shadows, blending, filter
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            guard let style = MapStyle(rawValue: try values.decode(String.self, forKey: .style)) else {
                throw DecodingError.dataCorruptedError(forKey: .style, in: values,
                                                      debugDescription: "Unknown map style")
            }
            self.style = style
            surface = try values.decode(Bool.self, forKey: .surface)
            y = try values.decode(Int.self, forKey: .y)
            guard let lighting = MapLightingMode(rawValue: try values.decode(String.self, forKey: .lighting)) else {
                throw DecodingError.dataCorruptedError(forKey: .lighting, in: values,
                                                      debugDescription: "Unknown map lighting mode")
            }
            self.lighting = lighting
            shadows = try values.decode(Bool.self, forKey: .shadows)
            blending = try values.decode(Bool.self, forKey: .blending)
            filter = try values.decode(Filter.self, forKey: .filter)
        }
    }
    nonisolated struct View: Decodable, Sendable {
        let id: String
        let center: [Double]
        let scale: Double
        let size: [Double]
    }
    nonisolated struct Configuration: Decodable, Sendable {
        let mode: String
        let world: String
        let game: String
        let output: String
        let artwork: Bool
        let cacheSeed: String?
        let worldFiles: [String: String]
        let gameFiles: [String: String]
        let states: [State]
        let views: [View]
    }
    enum Failure: Error {
        case configuration
        case missingCoverage(String)
    }
    actor Scans {
        var paths: [String] = []
        func record(_ value: String) { paths.append(value) }
    }
    final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_MAP_COMPARISON"] != nil),
          .timeLimit(.minutes(10)))
    func copiedWorldProof() async throws {
        try #require(Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests")
        let path = try #require(ProcessInfo.processInfo.environment["CHUNKSEE_MAP_COMPARISON"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        let root = "/Users/ryan/Developer/Chunksee-runs/"
        try #require(config.mode == "writer" || config.mode == "reuse")
        try #require(config.world == root + "world-snapshot-loaders-evidence/game-assets/paired-1/input-world")
        try #require(config.game == root + "naming-stack-comparison-evidence/inputs-1/input-game")
        try #require(config.output.hasPrefix(NSHomeDirectory() + "/Library/Caches/MapComparison-"))
        try #require((config.mode == "reuse") == (config.cacheSeed != nil))
        if let seed = config.cacheSeed {
            try #require(seed.hasPrefix(root + "map-presentation-drawing-comparison-evidence/immutable-caches/"))
            let url = URL(filePath: seed, directoryHint: .isDirectory)
            try #require(url.standardizedFileURL.path == url.path)
            try #require(url.resolvingSymlinksInPath().path == url.path)
        }
        try #require(config.states.map(\.id) == [
            "normal-surface", "height-surface", "water-depth-surface", "normal-saved-shadows",
            "water-depth-saved-shadows", "normal-cutaway", "normal-filter", "normal-disabled-filter",
            "normal-blended", "height-resolved-inputs",
        ])
        try #require(config.views.map(\.id) == ["boundary", "water-close"])
        for view in config.views {
            let finite = view.center.allSatisfy(\.isFinite)
            try #require(view.center.count == 2 && finite && view.size == [512, 384])
        }
        try #require(config.views[0].center == [-1, -256] && config.views[0].scale == 1)
        try #require(config.views[1].center == [-256, -256] && config.views[1].scale == 8)
        try #require(Locale.current.identifier == "en_US")
        try #require(Locale.preferredLanguages.first?.hasPrefix("en") == true)
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        try #require(output.standardizedFileURL.path == output.path)
        try #require(output.resolvingSymlinksInPath().path == output.path)
        try #require(!FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await MapComparisonFiles.verify(URL(filePath: config.world), expected: config.worldFiles)
        try await MapComparisonFiles.verify(URL(filePath: config.game), expected: config.gameFiles)
        let owners = try await Self.run(config, output: output)
        try #require(owners.allSatisfy { $0.value == nil })
        try await MapComparisonFiles.verify(URL(filePath: config.world), expected: config.worldFiles)
        try await MapComparisonFiles.verify(URL(filePath: config.game), expected: config.gameFiles)
        try MapComparisonEvidence.write(["completion.json": MapComparisonEvidence.json([
            "mode": config.mode, "artwork": config.artwork, "drained": true, "retainedOwners": 0,
            "processLocale": Locale.current.identifier, "preferredLanguages": Locale.preferredLanguages,
            "renderLocale": MapComparisonEvidence.locale.identifier,
        ])], to: output)
    }

    static func run(_ config: Configuration, output: URL) async throws -> [Weak] {
        let defaults = TestDefaults.make()
        try MapComparisonFixture.seed(defaults)
        let cache = output.appendingPathComponent("cache", isDirectory: true)
        if let seed = config.cacheSeed {
            try await MapComparisonFiles.copyCache(from: URL(filePath: seed, directoryHint: .isDirectory), to: cache)
        }
        let tileDirectory = try #require(TileCache.directory(forWorldAt: URL(filePath: config.world),
            dimensionID: MapComparisonFixture.dimension, root: cache))
        let before = config.mode == "reuse" ? try await MapComparisonFiles.snapshot(tileDirectory) : nil
        if let before {
            let dates = try await MapComparisonFiles.directoryDates(cache)
            try MapComparisonEvidence.write([
                "cache-files-before.json": MapComparisonEvidence.encoded(before),
                "cache-directory-dates-before.json": MapComparisonEvidence.encoded(dates),
            ], to: output)
        }
        let names = PlayerNames(defaults: defaults)
        var world: WorldResources?, session: WorldSession?
        var owners = [Weak(names), Weak(names.minecraft)]
        let scans = Scans()
        var stage = "open"
        MapComparisonTrace.begin()

        func open() async throws -> WorldSession {
            let snapshot = try await WorldSnapshot.read(URL(filePath: config.world, directoryHint: .isDirectory))
            let prepared = try await WorldPreparation.read(snapshot, minecraft: names.minecraft)
            let resources = WorldResources(prepared: prepared, names: names,
                savedSearches: SavedSearches(defaults: defaults),
                settings: WorldSettings(id: MapComparisonFixture.worldID, defaults: defaults),
                cacheRoot: cache, watchWorld: { _, _ in nil },
                readRegion: { dimension, region, options in
                    await scans.record("\(dimension.id)/\(region.x),\(region.z)")
                    return try await RegionReader.scan(dimension, region: region, options: options)
                })
            world = resources
            let current = WorldSession(resources: resources, dimensionID: MapComparisonFixture.dimension)
            session = current
            owners += [Weak(resources), Weak(resources.index), Weak(resources.queryStore), Weak(current)]
            if let map = current.map { owners.append(Weak(map)) }
            owners += resources.readers.values.map { Weak($0) }
            resources.refreshGameLanguage(preferredLanguage: "en_US")
            await settle(current)
            try #require(resources.mapGameResources.data != nil)
            try #require((resources.mapGameResources.artwork != nil) == config.artwork)
            return current
        }

        func close() async {
            session?.close()
            await session?.waitUntilClosed()
            world?.close()
            await world?.waitUntilClosed()
            session = nil
            world = nil
        }

        do {
            try #require(!names.looksUpOnline)
            names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
            names.minecraft.usesGameArtwork = config.artwork
            var current = try await open()
            try MapComparisonFixture.requireInitialChoices(current)
            var imageCount = 0
            if config.mode == "writer" {
                try MapComparisonFixture.capture(defaults, settings: current.resources.settings,
                    to: output.appendingPathComponent("settings-initial"))
                try MapComparisonEvidence.write([
                    "choices.json": MapComparisonEvidence.json(MapComparisonState.choices(current)),
                ], to: output.appendingPathComponent("settings-initial"))
                stage = "states"
                imageCount += try await states(config, session: current, output: output)
                stage = "overlays"
                imageCount += try await overlays(config, session: current, output: output)
                stage = "definitions"
                imageCount += try await definitions(config, session: current, output: output)
                try #require(imageCount == 148)
                let expected = try MapComparisonEvidence.json(MapComparisonState.choices(current))
                try MapComparisonEvidence.write(["choices.json": expected],
                    to: output.appendingPathComponent("settings-before-close"))
                try MapComparisonFixture.capture(defaults, settings: current.resources.settings,
                    to: output.appendingPathComponent("settings-before-close"))
                stage = "close-reopen"
                await close()
                current = try await open()
                let restored = try MapComparisonEvidence.json(MapComparisonState.choices(current))
                try MapComparisonEvidence.write(["choices.json": restored],
                    to: output.appendingPathComponent("settings-reopened"))
                try MapComparisonFixture.capture(defaults, settings: current.resources.settings,
                    to: output.appendingPathComponent("settings-reopened"))
                try #require(expected == restored)
            }
            stage = "canonical-cache"
            try await canonical(config, session: current, output: output)
            let map = try #require(current.map)
            await map.waitForRenders()
            try #require(map.unfinishedCacheWrites == 0)
            stage = "close"
            await close()
            let events = MapComparisonTrace.end()
            let after = try await MapComparisonFiles.snapshot(tileDirectory)
            let dates = try await MapComparisonFiles.directoryDates(cache)
            try MapComparisonEvidence.write([
                "cache-events.json": MapComparisonEvidence.encoded(events),
                "cache-files-after.json": MapComparisonEvidence.encoded(after),
                "cache-directory-dates-after.json": MapComparisonEvidence.encoded(dates),
                "aggregate-region-reads.json": MapComparisonEvidence.encoded(await scans.paths),
                "counts.json": MapComparisonEvidence.json(["writerImages": imageCount]),
            ], to: output)
            if let before {
                try #require(after == before)
                try #require(!events.contains { $0.kind == .surface || $0.kind == .tileMiss || $0.kind == .detailMiss })
            } else {
                try #require(events.contains { $0.kind == .surface })
            }
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
            return owners
        } catch {
            await close()
            let events = MapComparisonTrace.end()
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
            let category: String
            if let failure = error as? Failure, case .missingCoverage = failure {
                category = "inconclusive-input-coverage"
            }
            else { category = "check-failed" }
            try? MapComparisonEvidence.write([
                "failure.json": MapComparisonEvidence.json([
                    "stage": stage, "category": category, "error": String(describing: error),
                ]),
                "partial-cache-events.json": MapComparisonEvidence.encoded(events),
                "partial-aggregate-region-reads.json": MapComparisonEvidence.encoded(await scans.paths),
            ], to: output)
            throw error
        }
    }

    static func requireCoverage(_ condition: Bool, _ description: String) throws {
        guard condition else {
            throw Failure.missingCoverage(description)
        }
    }

    static func settle(_ session: WorldSession) async {
        await session.resources.waitForRefresh()
        await session.resources.backgroundWork.waitUntilFinished()
        await session.search.waitForIndex()
        await session.search.waitForSearch()
        await session.resources.index.waitForProjection()
        await session.heatMap.waitForReads()
        await session.slimeChunks.waitForImages()
        await session.map?.waitUntilIdle()
        await session.map?.waitForRenders()
        await session.map?.waitForTopBlocks()
    }

    static func apply(_ state: State, to session: WorldSession) throws {
        let map = try #require(session.map)
        map.setStyle(state.style)
        map.setDepth(MapDepth(y: state.y, isSurface: state.surface))
        map.setLightingMode(state.lighting)
        map.setCastsShadows(state.shadows)
        map.setBiomeBlending(state.blending)
        map.setBlockFilter(MapBlockFilter(isEnabled: state.filter.enabled,
            hiddenIDs: Set(state.filter.hidden), highlightedIDs: Set(state.filter.highlighted)))
    }

    static func hideOverlays(_ session: WorldSession) throws {
        session.selection.choose(nil)
        session.visibility.structures = []
        session.visibility.places = []
        session.visibility.creatures = []
        session.visibility.mobTypes = []
        session.visibility.mobAppearances = [:]
        session.visibility.biomes = []
        session.visibility.hiddenPlayers = Set(session.players.map(\.uuid))
        session.visibility.showsGrid = false
        session.visibility.showsSavedPlaces = false
        session.visibility.showsWorldBorder = false
        for name in ["Time Spent", "Slime Chunks", "Dark Spots"] {
            try MapComparisonAdapter.setOverlay(name, shown: false, in: session)
        }
    }

    static func show(_ view: View, in session: WorldSession) async throws {
        let map = try #require(session.map)
        map.viewport = MapViewport(center: CGPoint(x: view.center[0], y: view.center[1]), scale: view.scale)
        map.requestTiles(visibleIn: MapComparisonEvidence.size, displayScale: 1)
        await settle(session)
    }
}

