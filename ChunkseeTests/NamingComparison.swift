import ChunkseeIndex
import ChunkseeKit
import CryptoKit
import Foundation
import Testing
@testable import ChunkseeTestHost

/// Evidence-only, untimed proof. Each invocation has one artwork choice and one fresh process.
/// A later timing plan must be reviewed separately; this entry point deliberately has no timing mode.
@Suite(.isolatedStores)
@MainActor
struct NamingComparison {
    nonisolated struct View: Decodable, Sendable {
        let id: String
        let center: [Double]
        let scale: Double
        let query: String
        let hidesBaseMarkers: Bool
        let selectedKind: String?
        let selectedID: String?
        let hover: [Double]
        let picks: [[Double]]
        let requiredDrawnIDs: [String]
        let allowsNoCaptions: Bool
        let expectedBlockID: String?
        let expectedWaterDepth: Int?
    }
    nonisolated struct Configuration: Decodable, Sendable {
        let mode: String
        let world: String
        let game: String
        let output: String
        let artwork: Bool
        let worldFiles: [String: String]
        let gameFiles: [String: String]
        let expectedLanguageValues: [String: [String: String]]
        let queries: [String]
        let requiredNonemptyQueries: [String]
        let savedQueries: [String]
        let views: [View]
        let structureGroups: [String]
        let placeGroups: [String]
        let creatureGroups: [String]
    }
    enum Failure: Error { case configuration, mismatch(String) }
    actor Scans {
        var paths: [String] = []
        func append(_ value: String) { paths.append(value) }
    }
    final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_NAMING_COMPARISON"] != nil),
          .timeLimit(.minutes(5)))
    func copiedWorldProof() async throws {
        try #require(Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests")
        let path = try #require(ProcessInfo.processInfo.environment["CHUNKSEE_NAMING_COMPARISON"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        let root = "/Users/ryan/Developer/Chunksee-runs/"
        try #require(config.mode == "proof")
        try #require(config.world == root + "world-snapshot-loaders-evidence/game-assets/paired-1/input-world")
        try #require(config.game == root + "naming-stack-comparison-evidence/inputs-1/input-game")
        try #require(config.output.hasPrefix(NSHomeDirectory() + "/Library/Caches/NamingComparison-"))
        try #require(!config.queries.isEmpty && !config.views.isEmpty)
        try #require(Set(config.queries).count == config.queries.count)
        try #require(Set(config.requiredNonemptyQueries).isSubset(of: Set(config.queries)))
        try #require(Set(config.views.map(\.id)).count == config.views.count)
        try #require(Set(config.views.map(\.scale)) == Set([1.0, 2.0, 8.0]))
        for view in config.views { try Self.validate(view) }
        // The runner sets these for the test process only; the Mac's settings stay untouched.
        try #require(Locale.current.identifier == "en_US")
        try #require(Locale.preferredLanguages.first?.hasPrefix("en") == true)
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        try #require(output.standardizedFileURL.path == output.path)
        try #require(output.resolvingSymlinksInPath().path == output.path)
        try #require(!FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await Self.verify(URL(filePath: config.world), against: config.worldFiles)
        try await Self.verify(URL(filePath: config.game), against: config.gameFiles)
        let owners = try await Self.run(config, output: output)
        try #require(owners.allSatisfy { $0.value == nil })
        try #require(NamingComparisonTrace.recorder == nil)
        try await Self.verify(URL(filePath: config.world), against: config.worldFiles)
        try await Self.verify(URL(filePath: config.game), against: config.gameFiles)
        try Self.write(["completion.json": NamingComparisonCapture.json([
            "drained": true, "retainedOwners": 0, "artwork": config.artwork,
            "processLocale": Locale.current.identifier, "preferredLanguages": Locale.preferredLanguages,
            "renderLocale": NamingComparisonCapture.locale.identifier,
        ])], to: output)
    }

    static func run(_ config: Configuration, output: URL) async throws -> [Weak] {
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults)
        try #require(!names.looksUpOnline)
        names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
        names.minecraft.usesGameArtwork = config.artwork
        let saved = SavedSearches(defaults: defaults)
        for query in config.savedQueries { saved.add(query) }
        for entry in saved.all { saved.setShown(entry.id, false) }
        var world: WorldResources?
        var sessions: [WorldSession] = []
        let scans = Scans()
        var stage = "open"

        func close() async {
            for session in sessions { session.close() }
            for session in sessions { await session.waitUntilClosed() }
            world?.close()
            await world?.waitUntilClosed()
            sessions = []
            world = nil
            names.minecraft.forget()
            await names.minecraft.waitUntilIdle()
        }
        do {
            let initialSnapshot = try await WorldSnapshot.read(URL(filePath: config.world, directoryHint: .isDirectory))
            world = try await WorldResources(snapshot: initialSnapshot, names: names,
                savedSearches: saved, defaults: defaults, cacheRoot: output.appendingPathComponent("cache"),
                watchWorld: { _, _ in nil },
                readRegion: { dimension, region, options in
                    await scans.append("\(dimension.id)/\(region.x),\(region.z)")
                    return try await RegionReader.scan(dimension, region: region, options: options)
                })
            let resources = try #require(world)
            for _ in 0..<2 {
                let session = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
                sessions.append(session)
                session.visibility.structures = try Set(config.structureGroups.map {
                    try #require(StructureGroup(rawValue: $0))
                })
                session.visibility.places = try Set(config.placeGroups.map {
                    try #require(PlaceGroup(rawValue: $0))
                })
                session.visibility.creatures = try Set(config.creatureGroups.map {
                    try #require(CreatureGroup(rawValue: $0))
                })
                session.visibility.mobTypes = []
                session.visibility.mobAppearances = [:]
                session.visibility.biomes = []
                session.visibility.hiddenPlayers = []
                session.visibility.showsGrid = false
                session.visibility.showsSavedPlaces = true
                session.visibility.showsWorldBorder = false
                session.slimeChunks.isShown = false
                session.heatMap.isShown = false
            }
            try #require(sessions[0].resources === sessions[1].resources)
            try #require(sessions[0].search.indexStore === sessions[1].search.indexStore)
            let owners = [Weak(resources), Weak(resources.index), Weak(resources.queryStore),
                          Weak(names), Weak(names.minecraft)] +
                sessions.flatMap { [Weak($0), Weak($0.search), Weak($0.map!)] } +
                resources.readers.values.map { Weak($0) }
            for (index, language) in ["en_US", "fr_FR", "en_US"].enumerated() {
                stage = "language-\(index)-\(language)"
                resources.refreshGameLanguage(preferredLanguage: language)
                await settle(sessions)
                try #require(resources.gameNames.identity != nil)
                let expectedLanguage = try #require(config.expectedLanguageValues[language])
                try #require(!expectedLanguage.isEmpty)
                for (key, value) in expectedLanguage {
                    try #require(resources.gameNames.name(key: key, fallback: "(missing)") == value)
                }
                let namesID = resources.gameNames.identity
                for session in sessions {
                    try NamingComparisonAdapter.requireNameContext(session, expected: namesID)
                }
                let folder = output.appendingPathComponent(stage)
                try await snapshot(sessions[0], to: folder)
                try syntheticNames(resources.gameNames, to: folder.appendingPathComponent("synthetic-names"))
                for (queryIndex, query) in config.queries.enumerated() {
                    for session in sessions { session.search.text = query }
                    for session in sessions { await session.search.waitForSearch() }
                    for (window, session) in sessions.enumerated() {
                        try write(["query-\(queryIndex)-window-\(window).json": NamingComparisonCapture.json([
                            "query": query,
                            "hits": session.search.results.map { hit($0, names: resources.gameNames) },
                        ])], to: folder)
                    }
                    try #require(sessions[0].search.results == sessions[1].search.results)
                    if config.requiredNonemptyQueries.contains(query) {
                        try #require(!sessions[0].search.results.isEmpty)
                    }
                    if query.hasPrefix("block:") {
                        try #require(sessions[0].search.results.count < WorldSearch.blockResultLimit)
                    }
                }
                var sawCollision = false
                for view in config.views {
                    var firstWindow: [String: Data]?
                    for (window, session) in sessions.enumerated() {
                        stage = "language-\(index)/\(view.id)/window-\(window)"
                        session.visibility.structures = view.hidesBaseMarkers ? [] : Set(config.structureGroups.compactMap(StructureGroup.init(rawValue:)))
                        session.visibility.places = view.hidesBaseMarkers ? [] : Set(config.placeGroups.compactMap(PlaceGroup.init(rawValue:)))
                        session.visibility.creatures = view.hidesBaseMarkers ? [] : Set(config.creatureGroups.compactMap(CreatureGroup.init(rawValue:)))
                        session.search.text = view.query
                        await session.search.waitForSearch()
                        let selected = try selection(view)
                        session.selection.choose(nil)
                        if let selected { try #require(session.selection.mapClicked(selected, y: nil) != nil) }
                        let map = try #require(session.map)
                        map.setDepth(MapDepth())
                        map.viewport = MapViewport(center: point(view.center), scale: view.scale)
                        map.requestTiles(visibleIn: NamingComparisonCapture.size, displayScale: 1)
                        await map.waitUntilIdle()
                        await map.waitForRenders()
                        await map.waitForTopBlocks()
                        let destination = folder.appendingPathComponent("\(view.id)/window-\(window)")
                        let artifacts = try await NamingComparisonCapture.capture(
                            session, picks: view.picks.map(point), hover: point(view.hover), to: destination)
                        let collision = try checkCaptions(artifacts, view: view)
                        sawCollision = sawCollision || collision
                        if let firstWindow { try #require(artifacts == firstWindow) }
                        else { firstWindow = artifacts }
                    }
                }
                try #require(sawCollision)
                try #require(resources.gameNames.identity == namesID)
                try #require(await scans.paths.sorted() == [
                    "minecraft:overworld/-1,-1", "minecraft:overworld/0,-1", "minecraft:overworld/4,-2",
                ])
            }
            try write(["region-reads.json": NamingComparisonCapture.json(await scans.paths)], to: output)
            await close()
            return owners
        } catch {
            await close()
            try? write(["failure.json": NamingComparisonCapture.json([
                "stage": stage, "error": String(describing: error),
                "regionReads": await scans.paths, "drained": true,
            ])], to: output)
            throw error
        }
    }

    static func settle(_ sessions: [WorldSession]) async {
        let resources = sessions[0].resources
        await resources.waitForRefresh()
        await resources.backgroundWork.waitUntilFinished()
        for session in sessions {
            await session.search.waitForIndex()
            await session.search.waitForSearch()
        }
        await resources.index.waitForProjection()
    }

    static func validate(_ view: View) throws {
        try #require(!view.id.isEmpty && view.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        try #require(view.center.count == 2 && view.hover.count == 2 && view.picks.allSatisfy { $0.count == 2 })
        let finiteCoordinates = (view.center + view.hover + view.picks.flatMap { $0 }).allSatisfy { $0.isFinite }
        try #require(finiteCoordinates)
        try #require([1.0, 2.0, 8.0].contains(view.scale))
        try #require((view.selectedKind == nil) == (view.selectedID == nil))
    }

    static func point(_ values: [Double]) -> CGPoint { CGPoint(x: values[0], y: values[1]) }

    static func selection(_ view: View) throws -> MapTarget? {
        guard let kind = view.selectedKind, let id = view.selectedID else { return nil }
        switch kind {
        case "structure": return .row(.structure(id))
        case "place": return .row(.place(id))
        case "creature": return .row(.creature(id))
        case "search": return .searchHit(id)
        case "player": return .row(.player(try #require(UUID(uuidString: id))))
        default: throw Failure.configuration
        }
    }

    static func checkCaptions(_ artifacts: [String: Data], view: View) throws -> Bool {
        var collision = false
        if let blockID = view.expectedBlockID {
            let data = try #require(artifacts["readout.json"])
            let readout = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let block = try #require(readout["raw"] as? [String: Any])
            try #require(block["id"] as? String == blockID)
            if let depth = view.expectedWaterDepth { try #require(block["waterDepth"] as? Int == depth) }
        }
        let bytes = try #require(artifacts["caption-passes.json"])
        let passes = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        try #require(!passes.isEmpty)
        for pass in passes {
            let drawn = try #require(pass["drawnIDs"] as? [String])
            let candidates = try #require(pass["candidates"] as? [[String: Any]])
            collision = collision || candidates.count > drawn.count
            try #require(Set(view.requiredDrawnIDs).isSubset(of: Set(drawn)))
            if view.allowsNoCaptions {
                try #require(view.scale == 1 && view.selectedKind == nil && drawn.isEmpty)
                try #require((pass["formatted"] as? [Any])?.isEmpty == true)
            } else {
                try #require(!drawn.isEmpty)
            }
        }
        return collision
    }

    static func write(_ artifacts: [String: Data], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in artifacts {
            try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }
}
