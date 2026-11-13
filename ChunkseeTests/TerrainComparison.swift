import Foundation
import Testing
@testable import ChunkseeTestHost

/// Test-only host for the frozen #565 comparison. Source, controls, preparation, native
/// correctness and a reservation are separate gates; this suite does not approve a run.
@Suite(.isolatedStores)
@MainActor
struct TerrainComparison {
    nonisolated enum Mode: String, Codable, Sendable { case preparation, timing }
    nonisolated enum Endpoint: String, Codable, Sendable { case baseline, candidate }

    nonisolated struct Configuration: Decodable, Sendable {
        let mode: Mode
        let endpoint: Endpoint
        let output: String
        let reference: String?
        let referenceSHA256: String?
    }

    nonisolated struct Reference: Codable, Sendable {
        let endpoint: Endpoint
        let productHead: String
        let workloadSHA256: String
        let exportReceiptAmendmentSHA256: String
        let files: [String: String]
    }

    enum Failure: Error { case missingCoverage(String) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_TERRAIN_COMPARISON"] != nil),
          .timeLimit(.minutes(3)))
    func copiedWorldRendering() async throws {
        try #require(Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests")
        let path = try #require(ProcessInfo.processInfo.environment["CHUNKSEE_TERRAIN_COMPARISON"])
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(filePath: path)))
        let workload = try TerrainComparisonWorkload.read()
        try #require(configuration.endpoint.rawValue == TerrainComparisonAdapter.endpoint)
        try #require(workload.productHeads[configuration.endpoint.rawValue] == TerrainComparisonAdapter.productHead)
        try #require(Locale.current.identifier == workload.environment.locale)
        try #require(Locale.preferredLanguages.first?.hasPrefix("en") == true)
        let output = URL(filePath: configuration.output, directoryHint: .isDirectory)
        let caches = NSHomeDirectory() + "/Library/Caches"
        try #require(output.deletingLastPathComponent().path == caches)
        try #require(output.lastPathComponent.hasPrefix("TerrainComparison-"))
        try #require(output.standardizedFileURL.path == output.path && output.resolvingSymlinksInPath().path == output.path)
        try #require(!FileManager.default.fileExists(atPath: output.path))
        let reference: Reference?
        if configuration.mode == .timing {
            let path = try #require(configuration.reference), hash = try #require(configuration.referenceSHA256)
            try #require(path.hasPrefix(TerrainComparisonWorkload.root))
            let data = try Data(contentsOf: URL(filePath: path))
            try #require(TerrainComparisonFiles.digest(data) == hash)
            let found = try JSONDecoder().decode(Reference.self, from: data)
            try #require(found.endpoint == configuration.endpoint && found.workloadSHA256 == TerrainComparisonWorkload.sha256)
            try #require(found.exportReceiptAmendmentSHA256 == TerrainComparisonWorkload.amendmentSHA256)
            try #require(found.productHead == workload.productHeads[configuration.endpoint.rawValue])
            reference = found
        } else {
            try #require(configuration.reference == nil && configuration.referenceSHA256 == nil)
            reference = nil
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await run(configuration, workload: workload, output: output, reference: reference)
    }

    private func run(_ configuration: Configuration, workload: TerrainComparisonWorkload.Declaration,
                     output: URL, reference: Reference?) async throws {
        let p2 = TerrainComparisonWorkload.root + "claude-565-native-inputs-1/"
        let worldURL = URL(filePath: p2 + "inputs/world-" + configuration.endpoint.rawValue, directoryHint: .isDirectory)
        let gameURL = URL(filePath: TerrainComparisonWorkload.root + "claude-native-463/Claude Older Game", directoryHint: .isDirectory)
        let expectedWorld = try TerrainComparisonFiles.manifest(p2 + "result/source-manifest.json",
                                                               sha256: workload.inputs.sourceManifestSHA256)
        let expectedGame = try TerrainComparisonFiles.manifest(p2 + "result/game-manifest.json",
                                                              sha256: workload.inputs.gameManifestSHA256)
        let spots = try Data(contentsOf: URL(filePath: p2 + "result/spots.json"))
        try #require(TerrainComparisonFiles.digest(spots) == workload.inputs.spotsSHA256)
        let world = TerrainComparisonWorld(environment: workload.environment)
        var stage = "inputs-before"
        var commonFiles: [String: String] = [:]
        var fields: [String: Double] = [:]
        var shadowCoverage = false

        func verifyInputs(_ label: String) async throws {
            let actualWorld = try await TerrainComparisonFiles.snapshot(worldURL)
            try TerrainComparisonFiles.write(["world.json": TerrainComparisonFiles.encoded(actualWorld)],
                                              to: output.appendingPathComponent(label))
            let actualGame = try await TerrainComparisonFiles.snapshot(gameURL)
            try TerrainComparisonFiles.write(["game.json": TerrainComparisonFiles.encoded(actualGame)],
                                              to: output.appendingPathComponent(label))
            try #require(actualWorld == expectedWorld && actualGame == expectedGame)
        }

        func compare(_ names: [String], prefix: String) throws {
            for name in names {
                let relative = prefix + "/" + name
                let bytes = try Data(contentsOf: output.appendingPathComponent(relative))
                let hash = TerrainComparisonFiles.digest(bytes)
                commonFiles[relative] = hash
                if let reference {
                    if reference.files[relative] != hash {
                        try TerrainComparisonFiles.write(["mismatch.json": TerrainComparisonFiles.json([
                            "file": relative, "actual": hash, "expected": reference.files[relative] as Any? ?? NSNull(),
                        ])], to: output)
                    }
                    try #require(reference.files[relative] == hash)
                }
            }
        }

        func intervals(_ artifacts: [String: Data], prefix: String, export: Bool = false) throws {
            let data = try #require(artifacts["intervals.json"])
            let values = try JSONDecoder().decode([String: TerrainComparisonMeasures.Interval].self, from: data)
            for (route, interval) in values {
                try #require(interval.wallSeconds.isFinite && interval.wallSeconds >= 0)
                try #require(interval.processCPUSeconds.isFinite && interval.processCPUSeconds >= 0)
                let name = export ? prefix : prefix + "/" + route
                fields[name + "/wallSeconds"] = interval.wallSeconds
                fields[name + "/processCPUSeconds"] = interval.processCPUSeconds
            }
        }

        do {
            try await verifyInputs(stage)
            stage = "open"
            try await world.open(world: worldURL, game: gameURL, cache: output.appendingPathComponent("cache"))
            for row in workload.views {
                let prefix = "view/" + row.id
                stage = prefix
                let folder = output.appendingPathComponent(prefix)
                let result = try await world.view(row) { session in
                    let receipt = try TerrainComparisonReceipts.view(session, environment: workload.environment,
                                                                     to: folder.appendingPathComponent("inputs"))
                    let object = try #require(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
                    let counts = try #require(object["selectedLayerCounts"] as? [String: Int])
                    let map = try #require(session.map)
                    if row.settings.gameArtwork && row.settings.style.inputs.detail && row.scale >= 8 {
                        try Self.coverage((counts["detail"] ?? 0) > 0, "Missing close-up detail: " + row.id)
                    } else { try #require(counts["detail"] == 0) }
                    if row.settings.style == .height {
                        try #require(map.lighting == nil && counts["shadow"] == 0)
                    }
                    if row.settings.lightingMode == .savedTime {
                        try Self.coverage(map.lighting != nil && session.details.dayTime != nil, "Missing saved lighting: " + row.id)
                    }
                    if row.settings.timeSpent {
                        try Self.coverage(object["visibleHeatNonempty"] as? Bool == true, "Empty visible Time Spent: " + row.id)
                    }
                    if row.settings.slimeChunks {
                        try Self.coverage(object["visibleSlimeNonempty"] as? Bool == true, "Empty visible Slime Chunks: " + row.id)
                    }
                    let artifacts = try TerrainComparisonRender.view(session, environment: workload.environment,
                                                                     to: folder.appendingPathComponent("render"))
                    return (artifacts, (counts["shadow"] ?? 0) > 0)
                }
                try #require(world.viewOwners.allSatisfy { $0.value == nil })
                shadowCoverage = shadowCoverage || result.1
                if configuration.mode == .timing { try intervals(result.0, prefix: prefix) }
                try compare(["inputs/inputs.json", "inputs/source-bounds.json", "inputs/derived-terrain-bounds.json", "render/native-receipt.json",
                             "render/native.png", "render/native.rgba", "render/copy.png", "render/copy.rgba"], prefix: prefix)
            }
            try Self.coverage(shadowCoverage, "No nonempty shadow mask in any selected view")
            for row in workload.exports {
                let prefix = "export/" + row.id
                stage = prefix
                let folder = output.appendingPathComponent(prefix)
                let artifacts = try await world.export(row) { session, plan in
                    let receipt = try TerrainComparisonReceipts.export(session, plan: plan, environment: workload.environment,
                                                                       to: folder.appendingPathComponent("inputs"))
                    let object = try #require(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
                    if row.settings.timeSpent {
                        try Self.coverage(object["visibleHeatNonempty"] as? Bool == true, "Empty export Time Spent")
                    }
                    if row.settings.lightingMode == .savedTime {
                        try Self.coverage(session.map?.lighting != nil, "Missing export saved lighting")
                    }
                    if configuration.mode == .preparation {
                        return try await TerrainComparisonExportPreparation.capture(session, plan: plan,
                            environment: workload.environment, to: folder.appendingPathComponent("render"))
                    }
                    return try await TerrainComparisonRender.export(session, plan: plan,
                        environment: workload.environment, to: folder.appendingPathComponent("render"))
                }
                try #require(world.viewOwners.allSatisfy { $0.value == nil })
                if configuration.mode == .timing { try intervals(artifacts, prefix: prefix, export: true) }
                try compare(["inputs/inputs.json", "render/export.png", "render/export.rgba", "render/progress.json"], prefix: prefix)
            }
            stage = "close"
            await world.close()
            try #require(world.owners.allSatisfy { $0.value == nil })
            stage = "inputs-after"
            try await verifyInputs(stage)
            if let reference { try #require(commonFiles == reference.files) }
            let resources = try TerrainComparisonMeasures.processResources()
            if configuration.mode == .timing {
                fields["host/peakRSSBytes"] = Double(try #require(resources["peakRSSBytes"] as? Int64))
                try #require(Set(fields.keys) == Set(workload.primaryFields.map(\.id)))
                try TerrainComparisonFiles.write(["primary-fields.json": TerrainComparisonFiles.encoded(fields)], to: output)
            }
            let captured = Reference(endpoint: configuration.endpoint,
                productHead: try #require(workload.productHeads[configuration.endpoint.rawValue]),
                workloadSHA256: TerrainComparisonWorkload.sha256,
                exportReceiptAmendmentSHA256: TerrainComparisonWorkload.amendmentSHA256, files: commonFiles)
            try TerrainComparisonFiles.write([
                "reference.json": TerrainComparisonFiles.encoded(captured),
                "process-resources.json": TerrainComparisonFiles.json(resources),
                "completion.json": TerrainComparisonFiles.json([
                    "mode": configuration.mode.rawValue, "endpoint": configuration.endpoint.rawValue,
                    "views": workload.views.count, "exports": workload.exports.count,
                    "retainedOwners": 0, "referenceMatched": reference != nil,
                    "preparationOnlyExportReceipts": configuration.mode == .preparation,
                ]),
            ], to: output)
        } catch {
            await world.close()
            try? TerrainComparisonFiles.write(["failure.json": TerrainComparisonFiles.json([
                "stage": stage, "mode": configuration.mode.rawValue, "error": String(describing: error),
                "category": error is Failure ? "inconclusive-input-coverage" : "failed",
                "retainedOwners": world.owners.filter { $0.value != nil }.count,
            ])], to: output)
            throw error
        }
    }

    private static func coverage(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure.missingCoverage(reason) }
    }
}
