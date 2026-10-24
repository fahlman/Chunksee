import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSurfaceDetailTests {
    private func chunk() throws -> MapSurfaceDetail.Chunk {
        var request = MapBlockColorRequest(state: .init("minecraft:grass_block", properties: ["snowy": "false"]))
        request.tints.append(.init(index: 0, color: 0x123456))
        let requests = [request, MapBlockColorRequest(state: .init("minecraft:oak_log", properties: ["axis": "x"]))]
        var columns = [RegionTileRenderer.Column?](repeating: .init(y: 12, color: MapColor(0x808080), waterDepth: 0), count: 256)
        columns[1]?.colorShade = 0.6
        columns[2]?.emphasis = .dimmed
        columns[3]?.emphasis = .highlighted
        columns[4]?.waterDepth = 2
        columns[5] = nil
        var indices = [Int?](repeating: 0, count: 256)
        indices[6] = 1
        indices[7] = nil
        return try #require(MapSurfaceDetail.Chunk(columns: columns, requests: requests, indices: indices))
    }

    @Test func chunkPaletteKeepsTintStateAndPresentationWithoutDuplicatingEveryColumn() throws {
        let chunk = try chunk()
        #expect(chunk.materials.count == 4 && chunk.indices.count == 256)
        #expect(chunk.indices[0] == chunk.indices[255])
        #expect(chunk.materials[Int(chunk.indices[0])].request.tints.color(at: 0) == 0x123456)
        #expect(chunk.materials[Int(chunk.indices[1])].colorShade == 0.6)
        #expect(chunk.materials[Int(chunk.indices[2])].emphasis == .dimmed)
        #expect(chunk.materials[Int(chunk.indices[6])].request.state.properties == ["axis": "x"])
        for index in [3, 4, 5, 7] { #expect(chunk.indices[index] == MapSurfaceDetail.noMaterial) }
        #expect(chunk.estimatedBytes < 4096)
    }

    @Test func materialCacheRoundTripPreservesChunkAddressesAndRejectsMalformedIndices() throws {
        var detail = MapSurfaceDetail()
        detail.insert(try chunk(), at: 0)
        detail.insert(try chunk(), at: 1023)
        let bytes = try #require(detail.encoded())
        #expect(MapSurfaceDetail.decoded(bytes) == detail)
        #expect(MapSurfaceDetail.decoded(Data())?.isEmpty == true)
        #expect(MapSurfaceDetail.decoded(Data([0, 1, 2])) == nil)
        #expect(MapSurfaceDetail.decoded(Data(repeating: 0, count: MapSurfaceDetail.maximumEncodedBytes + 1)) == nil)
        let original = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        for mutation in 0..<7 {
            var archive = original
            var records = try #require(archive["chunks"] as? [[String: Any]])
            switch mutation {
            case 0: records[0]["index"] = -1
            case 1: records[1]["index"] = records[0]["index"]
            case 2: records[0]["indices"] = Data([0])
            case 3: records[0]["indices"] = Data(repeating: 0x80, count: 512)
            case 4: records[0]["materials"] = Data([0])
            case 5: records[0]["materials"] = Data([255, 255])
            default: archive["materials"] = []
            }
            archive["chunks"] = records
            let bad = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            #expect(MapSurfaceDetail.decoded(bad) == nil)
        }
    }

    @Test func repeatedMaterialsAcrossAFullRegionKeepTheirLocalColumnAddresses() throws {
        let chunk = try chunk()
        let alternate = try #require(MapSurfaceDetail.Chunk(
            columns: [RegionTileRenderer.Column?](repeating: .init(y: 12, color: MapColor(0x808080), waterDepth: 0), count: 256),
            requests: chunk.materials.reversed().map(\.request),
            indices: (0..<256).map { Optional($0 % chunk.materials.count) }))
        var detail = MapSurfaceDetail()
        for index in 0..<1024 { detail.insert(index.isMultiple(of: 2) ? chunk : alternate, at: index) }
        let data = try #require(detail.encoded())
        let restored = try #require(MapSurfaceDetail.decoded(data))
        #expect(restored == detail && restored.chunks.count == 1024)
        #expect(restored.estimatedBytes == detail.estimatedBytes)
        for index in 0..<1024 {
            let value = try #require(restored.chunks[index])
            let expected = index.isMultiple(of: 2) ? chunk : alternate
            #expect(value.indices == expected.indices && value.materials == expected.materials)
        }
    }

    @Test func retainedMaterialBudgetIsIndependentOfChunkCompletionOrder() throws {
        let requests = (0..<256).map { MapBlockColorRequest(state: .init("minecraft:material_\($0)_" + String(repeating: "a", count: 100))) }
        let columns = [RegionTileRenderer.Column?](repeating: .init(y: 1, color: MapColor(0x808080), waterDepth: 0), count: 256)
        let chunk = try #require(MapSurfaceDetail.Chunk(columns: columns, requests: requests, indices: (0..<256).map(Optional.some)))
        var forward = MapSurfaceDetail(), reverse = MapSurfaceDetail()
        for index in 0..<1024 { forward.insert(chunk, at: index) }
        for index in (0..<1024).reversed() { reverse.insert(chunk, at: index) }
        #expect(forward == reverse)
        #expect(!forward.isEmpty && forward.chunks.count < 1024)
        #expect(forward.estimatedBytes <= MapSurfaceDetail.maximumRetainedBytes)
        let data = try #require(forward.encoded())
        #expect(data.count <= MapSurfaceDetail.maximumEncodedBytes)
        #expect(MapSurfaceDetail.decoded(data) == forward)
    }

    @Test func ordinaryTerrainCacheIsIndependentOfMissingOrMalformedDetail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DetailCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TileCache(directory: directory)
        let key = TileCache.Key(region: .init(x: -1, z: 0), fileSize: 1, modified: 2, colorSource: "test-assets")
        var surface = RegionTileRenderer.Canvas()
        surface.detail.insert(try chunk(), at: 0)
        surface.heights[0] = 12
        cache.store(surface, for: key)
        let loaded = try #require(cache.load(key))
        #expect(loaded.detail.isEmpty && loaded.heights == surface.heights)
        #expect(cache.loadDetail(key) == nil)
        let file = directory.appendingPathComponent(key.fileName)
        let ordinary = try Data(contentsOf: file)
        cache.storeDetail(surface, for: key)
        let detail = try #require(cache.loadDetail(key))
        #expect(detail.detail == surface.detail && detail.heights == surface.heights)
        #expect(try Data(contentsOf: file) == ordinary)
        let detailFile = directory.appendingPathComponent(key.detailFileName)
        let bytes = try (Data(contentsOf: detailFile) as NSData).decompressed(using: .lzfse) as Data
        for bad in [Data(bytes.dropLast()), Data(bytes.prefix(512 * 512 * 4 - 1)),
                    Data(repeating: 0, count: 512 * 512 * 4 + MapSurfaceDetail.maximumEncodedBytes + 1)] {
            try ((bad as NSData).compressed(using: .lzfse) as Data).write(to: detailFile)
            #expect(cache.loadDetail(key) == nil)
            #expect(cache.load(key)?.heights == surface.heights)
        }
        cache.storeDetail(surface, for: key)
        cache.store(surface, for: key)
        #expect(cache.loadDetail(key)?.detail == surface.detail) // rewriting the tile keeps its sidecar
        var changed = key
        changed.modified += 1
        cache.store(surface, for: changed)
        #expect(cache.load(key) == nil && cache.loadDetail(key) == nil)
        #expect(cache.load(changed) != nil && cache.loadDetail(changed) == nil)
    }

    @Test func nighttimeDetailRoundTripsAndDoesNotReplaceOrdinaryTilesOrSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NightDetailCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TileCache(directory: directory)
        let ordinary = TileCache.Key(region: .init(x: -1, z: -1), fileSize: 1, modified: 2, colorSource: "test-assets")
        var night = ordinary
        night.nightLight = "unknown"
        var surface = RegionTileRenderer.Canvas()
        surface.detail.insert(try chunk(), at: 0)
        surface.heights[0] = 12
        cache.store(surface, for: ordinary)
        cache.storeDetail(surface, for: ordinary)
        let day = try #require(cache.loadDetail(ordinary))
        let count = surface.heights.count
        surface.nightLight = (0..<count).map { UInt8($0 % 3) }
        cache.store(surface, for: night)
        cache.storeDetail(surface, for: night)
        let restored = try #require(cache.loadDetail(night))
        #expect(restored.detail == day.detail && restored.heights == day.heights)
        #expect(restored.nightLight == surface.nightLight && restored.estimatedBytes == day.estimatedBytes + count)
        #expect(cache.load(ordinary)?.nightLight == nil && cache.loadDetail(ordinary)?.nightLight == nil)
        #expect(cache.load(night)?.nightLight == restored.nightLight)
        let file = directory.appendingPathComponent(night.detailFileName)
        var bytes = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        bytes[count * 4] = 3 // Unknown must be encoded explicitly, never inferred from invalid data.
        try ((bytes as NSData).compressed(using: .lzfse) as Data).write(to: file)
        #expect(cache.loadDetail(night) == nil)
        #expect(cache.load(night)?.nightLight == restored.nightLight)
        #expect(cache.loadDetail(ordinary)?.detail == day.detail)
    }
}
