import ChunkseeKit
import CoreGraphics
import CryptoKit
import Foundation
import Darwin
import Testing
@testable import ChunkseeTestHost

/// Evidence-only copied-world observation comparison; excluded from the product PR.
@Suite(.isolatedStores) struct MapColorComparison {
    nonisolated struct Configuration: Decodable, Sendable {
        let world: String
        let game: String
        let output: String
        let expected: String?
        let repetitions: Int
        let artworkModes: [Bool]
        let timing: Bool
        let traced: Bool
    }
    enum Failure: Error { case configuration, mismatch(String), cache(String), document, pixels }
    actor Scans {
        private(set) var calls = 0
        func record() { calls += 1 }
    }
    struct View {
        let region: RegionPosition
        let tile: CachedMapImage
        let preview: CachedMapImage
        let shadow: CGImage?
        let readout: RegionTileRenderer.TopBlock?
    }
    typealias Stamp = MapColorComparisonStamp

    @Test(.timeLimit(.minutes(5))) func compare() async throws {
        guard Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests",
              let path = ProcessInfo.processInfo.environment["CHUNKSEE_MAP_COLOR_COMPARISON"] else {
            throw Failure.configuration
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        guard config.traced == MapColorComparisonMetrics.tracing,
              !(config.traced && config.timing), (1...9).contains(config.repetitions),
              !config.artworkModes.isEmpty, Set(config.artworkModes).count == config.artworkModes.count,
              config.world == "/Users/ryan/Developer/Chunksee-runs/world-snapshot-loaders-evidence/game-assets/paired-1/input-world",
              config.game == "/Users/ryan/Developer/Chunksee-runs/world-snapshot-loaders-evidence/game-assets/paired-1/input-game",
              config.output.hasPrefix("/Users/ryan/Developer/Chunksee-runs/map-color-readiness-evidence/") else {
            throw Failure.configuration
        }
        let output = URL(filePath: config.output, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("records.json").path),
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("failure.json").path) else {
            throw Failure.configuration
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let expected: [String: String] = try config.expected.map {
            try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(filePath: $0)))
        } ?? [:]
        let world = URL(filePath: config.world, directoryHint: .isDirectory)
        let game = URL(filePath: config.game, directoryHint: .isDirectory)
        let regions = [RegionPosition(x: -1, z: -1), RegionPosition(x: 0, z: -1), RegionPosition(x: 4, z: -2)]
        var signatures: [String: String] = [:], records: [[String: Any]] = []

        for repetition in 0..<config.repetitions {
            for artwork in config.artworkModes {
                let cache = output.appendingPathComponent("cache-\(repetition)-\(artwork)")
                var coldFinalFiles: [String: String] = [:]
                for phase in ["cold", "reopen"] {
                    let key = "\(artwork ? "artwork-on" : "artwork-off")-\(phase)"
                    let rowStart = DispatchTime.now().uptimeNanoseconds
                    MapColorComparisonMetrics.beginRow("rep-\(repetition)/" + key)
                    let defaults = TestDefaults.make(), scans = Scans()
                    let model = AppModel(defaults: defaults, cacheRoot: cache, readRegion: { dimension, region, options in
                        await scans.record()
                        return try await RegionReader.scan(dimension, region: region, options: options)
                    })
                    model.names.minecraft.choose(game)
                    model.names.minecraft.usesGameArtwork = artwork
                    try model.worldFolders.remember(world)
                    let reader = WorldDocument.Reader(folders: model.worldFolders, model: model)
                    var session: WorldSession?
                    var stage = "opening"
                    var timings: [String: [String: Double]] = [:]
                    var failed: (any Error)?
                    func close() async {
                        session?.close()
                        await session?.waitUntilClosed()
                        model.names.minecraft.forget()
                        await model.names.minecraft.waitUntilIdle()
                    }
                    do {
                        let initialStart = Stamp()
                        MapColorComparisonMetrics.phase("initialReady", region: regions[0], since: initialStart)
                        guard case .dimension(let snapshot) = try await reader.readFolder(
                            world.appendingPathComponent("dimensions/minecraft/overworld")) else { throw Failure.document }
                        let opened = try await snapshot.makeSession(in: model)
                        session = opened
                        let resources = opened.resources, map = try #require(opened.map)
                        guard resources.refreshDelay == .seconds(2) else { throw Failure.configuration }
                        // Request the visible map before waiting for independent world publications.
                        Self.request(regions[0], on: map)
                        resources.refreshGameAssets()
                        await Self.settle(resources, map)
                        try #require(MapColorComparisonMetrics.snapshot.firstAcceptedTileSeen)
                        timings["initialFinalColorsReady"] = initialStart.values
                        let openingKey = try #require(map.tiles[regions[0]]).key
                        let openingPublications = try #require(MapColorComparisonMetrics.settled(key: openingKey))
                        timings["firstOpeningTile"] = openingPublications.firstTile
                        timings["firstFinalOpeningTile"] = openingPublications.firstFinalTile
                        let initialScans = await scans.calls
                        guard initialScans == (phase == "cold" ? 3 : 0) else {
                            throw Failure.cache("opening scans: \(initialScans), \(key)")
                        }
                        try Self.checkSource(map, artwork: artwork)
                        let player = try #require(resources.players.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.first)
                        opened.selection.inspector = .player(player.uuid)
                        await resources.playerRecords.waitUntilFinished()
                        let firstRecords = try #require(opened.selection.playerRecords?.records)
                        guard firstRecords.statistics != nil, !firstRecords.advancements.isEmpty,
                              !firstRecords.advancementDefinitions.isEmpty else {
                            throw Failure.mismatch("copied world did not exercise player records and titles")
                        }
                        timings["initialReady"] = initialStart.values

                        stage = "initial views"
                        MapColorComparisonMetrics.phase(stage)
                        MapColorComparisonMetrics.phase("initialDrawing")
                        let initialDrawingStart = Stamp()
                        let firstViews = try await Self.draw(regions, on: map)
                        timings["initialDrawing"] = initialDrawingStart.values
                        let initialMetrics = MapColorComparisonMetrics.snapshot
                        try Self.checkDrained(initialMetrics)
                        let initialProof = try await Self.proof(resources: resources, map: map, views: firstViews, records: firstRecords)
                        try Self.writeProof(initialProof, to: output.appendingPathComponent("rep-\(repetition)/" + key + "/initial"))
                        guard await scans.calls == initialScans else { throw Failure.cache("proof reread facts") }
                        let initialFiles = try Self.archiveSnapshot(cache)
                        if phase == "reopen", initialFiles != coldFinalFiles {
                            throw Failure.cache("unchanged reopen rewrote or added archives")
                        }

                        stage = "same-content refresh"
                        MapColorComparisonMetrics.phase(stage)
                        let colorReads = Scans(), readColors = resources.readBiomeColors
                        resources.readBiomeColors = { world, data, artwork, previous, reload in
                            await colorReads.record()
                            return try await readColors(world, data, artwork, previous, reload)
                        }
                        let retained = map.tiles
                        MapColorComparisonMetrics.phase("refresh")
                        let refreshStart = Stamp()
                        resources.worldChanged([world.appendingPathComponent("datapacks")])
                        await Self.settle(resources, map)
                        timings["refresh"] = refreshStart.values
                        guard await colorReads.calls == 1, await scans.calls == initialScans,
                              retained.count == map.tiles.count,
                              retained.allSatisfy({ map.tiles[$0.key] === $0.value }) else {
                            throw Failure.cache("same-content refresh changed images, scans or read count")
                        }
                        let refreshMetrics = MapColorComparisonMetrics.snapshot
                        try Self.checkDrained(refreshMetrics)

                        stage = "scheduled same-content refresh"
                        MapColorComparisonMetrics.phase(stage)
                        let burstReads = Scans()
                        resources.readBiomeColors = { world, data, artwork, previous, reload in
                            await colorReads.record(); await burstReads.record()
                            return try await readColors(world, data, artwork, previous, reload)
                        }
                        let burstTiles = map.tiles
                        MapColorComparisonMetrics.phase("scheduledRefresh")
                        let scheduledStart = Stamp()
                        let clock = ContinuousClock(), began = clock.now
                        var issueOffsets: [Double] = []
                        let notifications: [(Duration, String)] = [
                            (.zero, "datapacks"), (.milliseconds(2100), "datapacks"),
                            (.milliseconds(2200), "level.dat"),
                        ]
                        for (offset, path) in notifications {
                            // Supply external events independently of reader completion, not an async test wait.
                            try await clock.sleep(until: began.advanced(by: offset), tolerance: .zero)
                            let elapsed = began.duration(to: clock.now).components
                            issueOffsets.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                            resources.worldChanged([world.appendingPathComponent(path)])
                        }
                        await Self.settle(resources, map)
                        timings["scheduledRefresh"] = scheduledStart.values
                        let burstCount = await burstReads.calls
                        guard zip(issueOffsets, [0.0, 2.1, 2.2]).allSatisfy({ abs($0 - $1) <= 0.010 }) else {
                            throw Failure.mismatch("external notification schedule missed its 10 ms allowance")
                        }
                        guard (1...3).contains(burstCount), await scans.calls == initialScans,
                              burstTiles.count == map.tiles.count,
                              burstTiles.allSatisfy({ map.tiles[$0.key] === $0.value }) else {
                            throw Failure.cache("scheduled refresh changed images/scans or read count: \(burstCount)")
                        }
                        let burstMetrics = MapColorComparisonMetrics.snapshot
                        try Self.checkDrained(burstMetrics)
                        resources.readBiomeColors = { world, data, artwork, previous, reload in
                            await colorReads.record()
                            return try await readColors(world, data, artwork, previous, reload)
                        }

                        // No held asset read: source changes run under natural publication/cancellation.
                        stage = "source remove and rechoose"
                        MapColorComparisonMetrics.phase(stage)
                        let removalStart = Stamp()
                        MapColorComparisonMetrics.phase("remove", region: regions[2], since: removalStart)
                        model.names.minecraft.forget()
                        guard map.currentRenderer?.gameData == nil, map.currentRenderer?.gameArtwork == nil else {
                            throw Failure.mismatch("retired game remains connected")
                        }
                        await Self.settle(resources, map)
                        await model.names.minecraft.waitUntilIdle()
                        timings["remove"] = removalStart.values
                        let removalKey = try #require(map.tiles[regions[2]]).key
                        let removalPublications = try #require(MapColorComparisonMetrics.settled(key: removalKey))
                        timings["firstRemovalTile"] = removalPublications.firstTile
                        timings["firstFinalRemovalTile"] = removalPublications.firstFinalTile
                        let rechooseStart = Stamp()
                        MapColorComparisonMetrics.phase("rechoose", region: regions[2], since: rechooseStart)
                        model.names.minecraft.choose(game)
                        await Self.settle(resources, map)
                        await model.names.minecraft.waitUntilIdle()
                        try Self.checkSource(map, artwork: artwork)
                        timings["rechoose"] = rechooseStart.values
                        let rechooseKey = try #require(map.tiles[regions[2]]).key
                        let rechoosePublications = try #require(MapColorComparisonMetrics.settled(key: rechooseKey))
                        timings["firstRechooseTile"] = rechoosePublications.firstTile
                        timings["firstFinalRechooseTile"] = rechoosePublications.firstFinalTile
                        let sourceScans = await scans.calls
                        let sourceMetrics = MapColorComparisonMetrics.snapshot
                        try Self.checkDrained(sourceMetrics)

                        stage = "restored views"
                        MapColorComparisonMetrics.phase(stage)
                        MapColorComparisonMetrics.phase("restoredDrawing")
                        let restoredDrawingStart = Stamp()
                        let restoredViews = try await Self.draw(regions, on: map)
                        timings["restoredDrawing"] = restoredDrawingStart.values
                        let finalMetrics = MapColorComparisonMetrics.snapshot
                        try Self.checkDrained(finalMetrics)
                        let finalProof = try await Self.proof(resources: resources, map: map, views: restoredViews, records: try #require(opened.selection.playerRecords?.records))
                        try Self.writeProof(finalProof, to: output.appendingPathComponent("rep-\(repetition)/" + key + "/restored"))
                        guard initialProof == finalProof else {
                            let different = Set(initialProof.keys).union(finalProof.keys).filter { initialProof[$0] != finalProof[$0] }
                            throw Failure.mismatch("source cycle: " + different.sorted().joined(separator: ", "))
                        }
                        guard await scans.calls == sourceScans else { throw Failure.cache("final proof reread facts") }
                        let fields = finalProof.mapValues(Self.hash), signature = Self.hash(try Self.json(fields))
                        if phase == "reopen", signatures["\(artwork ? "artwork-on" : "artwork-off")-cold"] != signature {
                            throw Failure.mismatch("cold/reopen: " + key)
                        }
                        if config.expected != nil, expected[key] != signature { throw Failure.mismatch("baseline proof: " + key) }
                        if let previous = signatures[key], previous != signature {
                            throw Failure.mismatch("repetition output changed: " + key)
                        }
                        signatures[key] = signature

                        stage = "closing"
                        MapColorComparisonMetrics.phase(stage)
                        await close()
                        let finalFiles = try Self.archiveSnapshot(cache)
                        let cycleRewrites = finalFiles.filter { initialFiles[$0.key] != $0.value }.count
                        if phase == "cold" { coldFinalFiles = finalFiles }
                        let row: [String: Any] = [
                            "diagnosticOnly": config.traced, "tracedBuild": MapColorComparisonMetrics.tracing,
                            "key": key, "repetition": repetition,
                            "phase": config.timing ? (repetition == 0 ? "warmup" : "measured") : "diagnostic",
                            "timings": timings, "peakRSSBytes": Self.peakRSSBytes(),
                            "rowElapsedWallSeconds": Double(DispatchTime.now().uptimeNanoseconds - rowStart) / 1e9,
                            "tilePublications": try Self.object([
                                "opening": openingPublications, "remove": removalPublications, "rechoose": rechoosePublications
                            ]),
                            "signature": signature, "fields": fields,
                            "initialScans": initialScans, "sourceCycleScans": sourceScans - initialScans,
                            "sameContentColorReads": 1, "totalObservedColorReads": await colorReads.calls,
                            "initialMetrics": try Self.object(initialMetrics),
                            "refreshMetrics": try Self.object(refreshMetrics),
                            "burstMetrics": try Self.object(burstMetrics), "burstColorReads": burstCount,
                            "sourceMetrics": try Self.object(sourceMetrics),
                            "finalMetrics": try Self.object(finalMetrics),
                            "cycleRewrites": cycleRewrites, "initialCacheFiles": initialFiles,
                            "finalCacheFiles": finalFiles,
                            "notificationIssueOffsetsSeconds": issueOffsets,
                        ]
                        try Self.writeTrace(to: output.appendingPathComponent("rep-\(repetition)/" + key + "/diagnostic.json"))
                        records.append(row)
                        try Self.json(records).write(to: output.appendingPathComponent("records.json"))
                    } catch { failed = error }
                    if let error = failed {
                        let failedMetrics = MapColorComparisonMetrics.snapshot, failedScans = await scans.calls
                        await close()
                        let failure: [String: Any] = ["key": key, "stage": stage,
                            "error": String(describing: error), "metrics": (try? Self.object(failedMetrics)) ?? NSNull(),
                            "scans": failedScans]
                        try? Self.writeTrace(to: output.appendingPathComponent("diagnostic-failure.json"))
                        try? Self.json(failure).write(to: output.appendingPathComponent("failure.json"))
                        throw error
                    }
                }
            }
        }
        try Self.json(signatures).write(to: output.appendingPathComponent("proof.json"))
        print("MAP_COLOR_COMPARISON completed \(records.count) rows")
    }

    private static func writeTrace(to url: URL) throws {
#if CHUNKSEE_COLOR_TRACE
        let report = RechooseDiagnosticTrace.report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: url)
        guard !report.overflow else { throw Failure.mismatch("diagnostic trace overflow") }
#endif
    }

    private static func request(_ region: RegionPosition, on map: MapModel) {
        map.viewport = MapViewport(center: CGPoint(x: region.x * 512 + 256, y: region.z * 512 + 256), scale: 1)
        map.requestTiles(visibleIn: CGSize(width: 64, height: 64), displayScale: 1)
    }

    private static func settle(_ resources: WorldResources, _ map: MapModel) async {
        await resources.waitForRefresh()
        await resources.backgroundWork.waitUntilFinished()
        await map.waitUntilIdle()
        await map.waitForRenders()
        await map.waitForTopBlocks()
    }

    private static func checkSource(_ map: MapModel, artwork: Bool) throws {
        let renderer = try #require(map.currentRenderer)
        guard renderer.gameData != nil, (renderer.gameArtwork != nil) == artwork, renderer.biomeColors != nil else {
            throw Failure.mismatch("settled map lacks its selected source")
        }
    }

    private static func checkDrained(_ counts: MapColorComparisonMetrics.Snapshot) throws {
        guard counts.tileStarted == counts.tileFinished else {
            throw Failure.mismatch("parity case ended with unfinished map work")
        }
    }

    private static func draw(_ regions: [RegionPosition], on map: MapModel) async throws -> [View] {
        var views: [View] = []
        for region in regions {
            request(region, on: map)
            await map.waitUntilIdle(); await map.waitForRenders(); await map.waitForTopBlocks()
            let tile = try #require(map.tiles[region]), preview = try #require(map.previews[region])
            guard map.currentRenderer?.accepts(tile.key) == true, map.currentRenderer?.accepts(preview.key) == true else {
                throw Failure.mismatch("retired image key")
            }
            views.append(View(region: region, tile: tile, preview: preview, shadow: map.shadowImages[region],
                              readout: map.topBlock(at: map.viewport.center)))
        }
        return views
    }

    private static func proof(resources: WorldResources, map: MapModel, views: [View], records: PlayerRecords) async throws -> [String: Data] {
        var proof: [String: Data] = [:]
        for view in views {
            let prefix = "r\(view.region.x).\(view.region.z)"
            proof[prefix + "-full.rgba"] = try pixels(view.tile.picture.image)
            proof[prefix + "-preview.rgba"] = try pixels(view.preview.picture.image)
            proof[prefix + "-normals.rgba"] = try view.tile.picture.normals.map(pixels) ?? Data()
            proof[prefix + "-preview-normals.rgba"] = try view.preview.picture.normals.map(pixels) ?? Data()
            proof[prefix + "-shadow.rgba"] = try view.shadow.map(pixels) ?? Data()
            proof[prefix + "-readout.json"] = try json(view.readout.map { value in
                ["id": value.id, "y": value.y, "waterDepth": value.waterDepth,
                 "nightLight": value.nightLight.map { $0.rawValue as Any } ?? NSNull(),
                 "hasGameDefinition": value.hasGameDefinition.map { $0 as Any } ?? NSNull()] as [String: Any]
            } as Any? ?? NSNull())
        }
        proof["lighting.json"] = try json(map.savedLighting.map { light in
            ["sunAngle": light.saved.sunAngle, "moonAngle": light.saved.moonAngle,
             "skyLightFactor": light.saved.skyLightFactor,
             "skyLightColor": [light.saved.skyLightColor.x, light.saved.skyLightColor.y, light.saved.skyLightColor.z],
             "moonPhase": light.saved.moonPhase.rawValue] as [String: Any]
        } as Any? ?? NSNull())
        let renderer = try #require(map.currentRenderer)
        proof["source.json"] = try json([
            "data": renderer.gameData.map { $0.sourceKey as Any } ?? NSNull(),
            "artwork": renderer.gameArtwork.map { $0.sourceKey as Any } ?? NSNull(),
        ])
        let colors = try #require(renderer.biomeColors)
        proof["colors.json"] = try json(object(colors.sourceKey))
        for (dimensionID, reader) in resources.readers.sorted(by: { $0.key < $1.key }) {
            for region in reader.availableRegions.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
                let facts = try #require(await reader.facts(region))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                var values = try #require(JSONSerialization.jsonObject(with: encoder.encode(facts)) as? [String: Any])
                for field in ["blockIDs", "paletteBlockIDs"] {
                    if let items = values[field] as? [String] { values[field] = items.sorted() }
                }
                let name = dimensionID.replacingOccurrences(of: ":", with: "_") + "-\(region.x)-\(region.z).json"
                proof[name] = try json(values)
            }
        }
        proof["players-health.json"] = try json(resources.players.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.map { player in
            ["uuid": player.uuid.uuidString, "health": number(player.health), "maximum": number(player.maxHealth)] as [String: Any]
        })
        proof["player-records.json"] = try json([
            "statistics": records.statistics?.values as Any? ?? NSNull(),
            "statisticsVersion": records.statistics?.dataVersion as Any? ?? NSNull(),
            "statisticsName": records.statisticsName as Any? ?? NSNull(),
            "advancements": records.advancements.sorted { $0.id < $1.id }.map { progress in
                ["id": progress.id, "done": progress.isDone,
                 "criteria": progress.criteria.mapValues { $0.timeIntervalSince1970 }] as [String: Any]
            },
            "titles": records.advancementDefinitions.keys.sorted().map { id in
                ["id": id, "hasTitle": records.title(for: id) != nil,
                 "displayed": resources.gameNames.advancement(id, title: records.title(for: id))] as [String: Any]
            },
        ])
        return proof
    }

    nonisolated static func peakRSSBytes() -> Int64 {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Int64(usage.ru_maxrss)
    }

    nonisolated static func pixels(_ image: CGImage) throws -> Data {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data else { throw Failure.pixels }
        let bytes = data as Data
        guard bytes.count >= image.bytesPerRow * image.height else { throw Failure.pixels }
        var rows = Data(capacity: image.width * image.height * 4)
        for row in 0..<image.height {
            rows.append(bytes[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)])
        }
        return rows
    }
    nonisolated static func number(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value.isFinite ? value as Any : String(value) as Any
    }
    nonisolated static func archiveSnapshot(_ root: URL) throws -> [String: String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return try Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "lzfse" || $0.lastPathComponent.hasSuffix(".lzfse.detail") }.map { file in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let stamp = (attributes[.modificationDate] as! Date).timeIntervalSince1970
            let inode = attributes[.systemFileNumber] as! NSNumber
            return (String(file.path.dropFirst(root.path.count)), hash(try Data(contentsOf: file)) + ":\(stamp):\(inode)")
        })
    }
    nonisolated static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    nonisolated static func writeProof(_ proof: [String: Data], to directory: URL) throws {
        // Keep both sides of a mismatch, including results from a failing case.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in proof { try bytes.write(to: directory.appendingPathComponent(name)) }
    }
    nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
}
