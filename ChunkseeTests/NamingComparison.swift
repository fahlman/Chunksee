import ChunkseeIndex
import ChunkseeKit
import CryptoKit
import Foundation
import Testing
@testable import ChunkseeTestHost

/// One fixed workload: two artwork choices, each cold and reopened. A separately approved
/// controller decides whether this host is an output proof or a fresh-process repetition.
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_NAMING_TIMING"] != nil),
          .timeLimit(.minutes(5)))
    func copiedWorldProof() async throws {
        try #require(Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests")
        let path = try #require(ProcessInfo.processInfo.environment["CHUNKSEE_NAMING_TIMING"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        let root = "/Users/ryan/Developer/Chunksee-runs/"
        try #require(config.mode == "proof")
        try #require(config.world == root + "world-snapshot-loaders-evidence/game-assets/paired-1/input-world")
        try #require(config.game == root + "naming-stack-comparison-evidence/inputs-1/input-game")
        try #require(config.output.hasPrefix(NSHomeDirectory() + "/Library/Caches/NamingTiming-"))
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
        try #require(NamingComparisonMeasures.intendedFrenchQueries.isSubset(of: Set(config.queries)))
        try #require(config.queries.count == 17 && config.views.count == 8)
        // No fixed view draws one of the four intentionally expanded French searches.
        // Keep every view scored; this is checked against the immutable workload before a run.
        try #require(config.views.allSatisfy {
            !NamingComparisonMeasures.intendedFrenchQueries.contains($0.query)
        })
        var completed: [String] = []
        for artwork in [false, true] {
            let cell = "artwork-\(artwork ? "on" : "off")"
            let cache = output.appendingPathComponent("cache-" + cell)
            var coldFiles: [String: NamingComparisonMeasures.CacheFile] = [:]
            for phase in ["cold", "reopen"] {
                let folder = output.appendingPathComponent(cell + "/" + phase)
                let before = try await NamingComparisonMeasures.cacheFiles(cache)
                try #require(phase == "cold" ? before.isEmpty : before == coldFiles)
                let owners = try await Self.run(config, artwork: artwork, phase: phase,
                                               output: folder, cache: cache)
                try #require(owners.allSatisfy { $0.value == nil })
                let after = try await NamingComparisonMeasures.cacheFiles(cache)
                try #require(!after.isEmpty)
                try Self.write([
                    "cache-files-before.json": NamingComparisonCapture.encoded(before),
                    "cache-files-after.json": NamingComparisonCapture.encoded(after),
                ], to: folder)
                if phase == "cold" { coldFiles = after }
                else { try #require(before == after) }
                completed.append(cell + "/" + phase)
            }
        }
        try await Self.verify(URL(filePath: config.world), against: config.worldFiles)
        try await Self.verify(URL(filePath: config.game), against: config.gameFiles)
        try Self.write(["completion.json": NamingComparisonCapture.json([
            "drained": true, "retainedOwners": 0, "completedCells": completed,
            "processLocale": Locale.current.identifier, "preferredLanguages": Locale.preferredLanguages,
            "renderLocale": NamingComparisonCapture.locale.identifier,
        ])], to: output)
        try Self.write(["process-resources.json": NamingComparisonCapture.json(
            NamingComparisonMeasures.processResources())], to: output)
    }

    static func run(_ config: Configuration, artwork: Bool, phase: String, output: URL, cache: URL) async throws -> [Weak] {
        let setupStart = NamingComparisonMeasures.Stamp()
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults)
        try #require(!names.looksUpOnline)
        names.minecraft.choose(URL(filePath: config.game, directoryHint: .isDirectory))
        names.minecraft.usesGameArtwork = artwork
        let saved = SavedSearches(defaults: defaults)
        for query in config.savedQueries { saved.add(query) }
        for entry in saved.all { saved.setShown(entry.id, false) }
        var world: WorldResources?
        var sessions: [WorldSession] = []
        let scans = Scans()
        var stage = "open"
        var measures: [[String: Any]] = []
        var componentsActive = false
        let expectedReads = phase == "cold" ? [
            "minecraft:overworld/-1,-1", "minecraft:overworld/0,-1", "minecraft:overworld/4,-2",
        ] : []

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
            NamingPublicationProbe.start()
            componentsActive = true
            let initialStart = NamingComparisonMeasures.Stamp()
            let snapshotSpan = NamingPublicationProbe.begin(.worldSnapshot)
            let initialSnapshot = try await WorldSnapshot.read(URL(filePath: config.world, directoryHint: .isDirectory))
            NamingPublicationProbe.end(snapshotSpan)
            let remembered = try WorldFolders(defaults: defaults).remember(initialSnapshot.access.url)
            let preparationSpan = NamingPublicationProbe.begin(.worldPreparation)
            let prepared = try await WorldPreparation.read(initialSnapshot, minecraft: names.minecraft)
            NamingPublicationProbe.end(preparationSpan)
            world = WorldResources(prepared: prepared, names: names,
                savedSearches: saved, settings: WorldSettings(folder: remembered, defaults: defaults), cacheRoot: cache,
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
                let languageStart = NamingComparisonMeasures.Stamp()
                resources.refreshGameLanguage(preferredLanguage: language)
                await settle(sessions)
                let publicationEnd = NamingComparisonMeasures.Stamp()
                if index == 0 {
                    let report = NamingPublicationProbe.finish()
                    componentsActive = false
                    // Preserve raw spans before any validation or calculation can fail.
                    try write(["initial-components.json": NamingComparisonCapture.encoded(report)], to: output)
                    try #require(report.isComplete)
                    let summary = try report.summarized()
                    let counts = Dictionary(grouping: report.spans, by: { $0.phase.rawValue }).mapValues { $0.count }
                    for phase in ["worldSnapshot", "worldPreparation"] { try #require(counts[phase] == 1) }
                    for phase in ["regionIO", "regionProjection"] { try #require((counts[phase] ?? 0) >= 3) }
                    for phase in ["languageRead", "nameConstruction", "dimensionProjection", "indexSnapshot",
                                  "queryContext", "queryExecution", "namePublication", "indexPublication", "queryPublication"] {
                        try #require((counts[phase] ?? 0) > 0)
                    }
                    let carriedPets = resources.index.playerSnapshot.shoulderPets.count
                    if carriedPets > 0 { try #require((counts["carriedPetProjection"] ?? 0) > 0) }
                    try write([
                        "initial-component-summary.json": NamingComparisonCapture.encoded(summary),
                        "initial-component-coverage.json": NamingComparisonCapture.json([
                            "phaseCounts": counts, "carriedPets": carriedPets,
                            "openingStartNanoseconds": initialStart.wall,
                            "openingEndNanoseconds": publicationEnd.wall,
                            "threadCPUClock": "CLOCK_THREAD_CPUTIME_ID",
                        ]),
                    ], to: output)
                    measures.append(["operation": "cellSetup", "primary": false,
                        "interval": setupStart.until(initialStart)])
                    measures.append(["operation": "initialWorldRead", "primary": true,
                        "decisionFields": ["wallSeconds"],
                        "interval": ["wallSeconds": summary.worldReadWallSeconds],
                        "cpuScope": "Not attributed across asynchronous reads"])
                    measures.append(["operation": "initialNamesAndIndex", "primary": true,
                        "decisionFields": ["wallSeconds", "threadCPUSeconds"],
                        "interval": ["wallSeconds": summary.namesAndIndexWallSeconds,
                                     "threadCPUSeconds": summary.namesAndIndexThreadCPUSeconds]])
                    measures.append(["operation": "completeOpen", "primary": false,
                        "interval": initialStart.until(publicationEnd),
                        "scope": "Whole-process CPU is context, not the names-group CPU decision"])
                }
                let languageInterval = languageStart.until(publicationEnd)
                measures.append(["operation": "languagePublication", "languagePhase": index,
                    "language": language, "primary": index != 0,
                    "interval": index == 0 ? ["wallSeconds": languageInterval["wallSeconds"]!] : languageInterval])
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
                let captureStart = NamingComparisonMeasures.Stamp()
                try await snapshot(sessions[0], to: folder)
                let captureEnd = NamingComparisonMeasures.Stamp()
                measures.append(["operation": "publicationCapture", "languagePhase": index,
                    "primary": false, "interval": captureStart.until(captureEnd)])
                try write(["language-tables.json": NamingComparisonCapture.json(
                    NamingComparisonMeasures.languageTables(resources.gameNames))], to: folder)
                for (queryIndex, query) in config.queries.enumerated() {
                    let queryStart = NamingComparisonMeasures.Stamp()
                    for session in sessions { session.search.text = query }
                    for session in sessions { await session.search.waitForSearch() }
                    let queryEnd = NamingComparisonMeasures.Stamp()
                    measures.append(["operation": "queryPublication", "languagePhase": index,
                        "language": language, "query": query,
                        "primary": NamingComparisonMeasures.isScored(query: query, language: language),
                        "decision": NamingComparisonMeasures.isScored(query: query, language: language)
                            ? "scored" : "reported-intended-membership-change",
                        "resultCounts": sessions.map { $0.search.results.count },
                        "interval": queryStart.until(queryEnd)])
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
                for view in config.views {
                    var firstWindow: [String: String]?
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
                        try checkOutput(artifacts, view: view)
                        let signatures = artifacts.mapValues { data in
                            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        }
                        if let firstWindow { try #require(signatures == firstWindow) }
                        else { firstWindow = signatures }
                    }
                }
                try #require(resources.gameNames.identity == namesID)
                try #require(await scans.paths.sorted() == expectedReads)
            }
            let closeStart = NamingComparisonMeasures.Stamp()
            await close()
            let closeEnd = NamingComparisonMeasures.Stamp()
            measures.append(["operation": "closeAndDrain", "primary": false,
                "interval": closeStart.until(closeEnd)])
            try write([
                "region-reads.json": NamingComparisonCapture.json(await scans.paths),
                "measurements.json": NamingComparisonCapture.json(measures),
            ], to: output)
            return owners
        } catch {
            await close()
            if componentsActive {
                let report = NamingPublicationProbe.finish()
                componentsActive = false
                try? write(["failure-initial-components.json": NamingComparisonCapture.encoded(report)], to: output)
            }
            try? write(["failure.json": NamingComparisonCapture.json([
                "stage": stage, "error": String(describing: error),
                "regionReads": await scans.paths, "drained": true, "measurements": measures,
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

    /// The new untraced PNG and geometry must be compared with the approved endpoint capture.
    /// The retained proof established the caption families; this check does not claim a new trace.
    static func checkOutput(_ artifacts: [String: Data], view: View) throws {
        try #require(artifacts["render.png"] != nil)
        if let blockID = view.expectedBlockID {
            let data = try #require(artifacts["readout.json"])
            let readout = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let block = try #require(readout["raw"] as? [String: Any])
            try #require(block["id"] as? String == blockID)
            if let depth = view.expectedWaterDepth { try #require(block["waterDepth"] as? Int == depth) }
        }
    }

    static func write(_ artifacts: [String: Data], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in artifacts {
            try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }
}
