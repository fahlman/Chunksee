import ChunkseeKit
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Detailed export receipts exist only during preparation (export-receipts-amendment-1).
/// Timed hosts call TerrainComparisonRender.export, whose reader has no wrapper.
@MainActor
enum TerrainComparisonExportPreparation {
    actor Reader {
        private let folder: URL
        private var records: [Data] = []

        init(folder: URL) { self.folder = folder }

        func read(_ renderer: RegionTileRenderer, region: RegionPosition) async throws -> RegionTileRenderer.RenderedTile? {
            let index = records.count
            var record: [String: Any] = ["call": index, "region": [region.x, region.z]]
            records.append(try TerrainComparisonFiles.json(record))
            let output = folder.appendingPathComponent(String(format: "call-%04d", index))
            do {
                // Forward the same operation used by MapImage.export's default argument.
                // The returned tile, its pending cache write and its heights are unchanged.
                let result = try await renderer.tile(for: region)
                record["nil"] = result == nil
                if let result {
                    func image(_ value: MapTileImage, name: String) throws -> [String: Any] {
                        let (bytes, format) = try TerrainComparisonReceipts.packed(value.image)
                        try TerrainComparisonFiles.write([name + ".pixels": bytes], to: output)
                        var record = format
                        if let normals = value.normals {
                            let (bytes, format) = try TerrainComparisonReceipts.packed(normals)
                            try TerrainComparisonFiles.write([name + "-normals.pixels": bytes], to: output)
                            record["normals"] = format
                        } else { record["normals"] = NSNull() }
                        return record
                    }
                    record["full"] = try image(result.full, name: "full")
                    record["preview"] = try image(result.preview, name: "preview")
                    if let heights = result.heights {
                        let values = heights.map { $0.littleEndian }
                        let bytes = values.withUnsafeBytes { Data($0) }
                        try TerrainComparisonFiles.write(["heights.int32le": bytes], to: output)
                        record["heights"] = ["count": heights.count, "format": "Int32 little endian",
                                             "sha256": TerrainComparisonFiles.digest(bytes)] as [String: Any]
                    } else { record["heights"] = NSNull() }
                }
                records[index] = try TerrainComparisonFiles.json(record)
                try TerrainComparisonFiles.write(["read.json": records[index]], to: output)
                return result
            } catch {
                record["error"] = String(describing: error)
                records[index] = try TerrainComparisonFiles.json(record)
                try? TerrainComparisonFiles.write(["read-failed.json": records[index]], to: output)
                throw error
            }
        }

        func receipt() throws -> Data {
            try TerrainComparisonFiles.json(records.map { try JSONSerialization.jsonObject(with: $0) })
        }
    }

    static func capture(_ session: WorldSession, plan: MapExportPlan,
                        environment: TerrainComparisonWorkload.Environment, to folder: URL) async throws -> [String: Data] {
        let map = try #require(session.map), renderer = try requiredRenderer(map)
        let content = MapContent(session: session), regions = map.availableRegions
        let reader = Reader(folder: folder.appendingPathComponent("preparation-only"))
        var progress: [[Int]] = []
        var artifacts: [String: Data] = [:]
        do {
            let image = try await MapImage.export(plan: plan, regions: regions, renderer: renderer, content: content,
                portalStatus: { session.presentation.linkStatus(for: $0) }, colorScheme: .light,
                locale: environment.renderLocale, contrast: .standard,
                progress: { progress.append([$0, $1]) },
                readTile: { try await reader.read($0, region: $1) })
            artifacts["export.png"] = image.data
            artifacts["progress.json"] = try TerrainComparisonFiles.json(progress)
            artifacts["export.rgba"] = try TerrainComparisonRender.pixels(image, width: plan.width, height: plan.height)
            artifacts["preparation-only-reads.json"] = try await reader.receipt()
            let count = plan.viewport.visibleRegions(in: plan.size, among: regions).count
            try #require(count > 0 && progress == (0...count).map { [$0, count] })
            try TerrainComparisonFiles.write(artifacts, to: folder)
            return artifacts
        } catch {
            artifacts["progress.json"] = try? TerrainComparisonFiles.json(progress)
            artifacts["preparation-only-reads.json"] = try? await reader.receipt()
            try? TerrainComparisonFiles.write(artifacts, to: folder)
            throw error
        }
    }
}
