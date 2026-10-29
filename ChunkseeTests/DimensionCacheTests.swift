import CoreGraphics
import Foundation
import ChunkseeKit
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct DimensionCacheTests {
    @Test func equalRegionFingerprintsKeepEachDimensionsTerrainAndScans() async throws {
        let worldURL = try TestWorld.make(chunks: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DimensionCache-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: worldURL)
            try? FileManager.default.removeItem(at: root)
        }
        let examples = [("ice-caves", "minecraft:stone", 111),
                        ("ice_caves", "minecraft:sand", 222),
                        ("ice/caves", "minecraft:red_wool", 333)]
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let region = RegionPosition(x: 0, z: 0)
        var keys = Set<TileCache.Key>(), fingerprints = Set<[CacheKey.FileStamp?]>(), directories = Set<URL>()
        var referenceImages = Set<Data>()
        for (path, block, time) in examples {
            let folder = worldURL.appendingPathComponent("dimensions/example/\(path)/region")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var chunk = TestWorld.chunk(x: 0, z: 0, palette: [block]) { _, _, _ in 0 }
            var fields = try #require(chunk.nbt.compound)
            fields["InhabitedTime"] = .long(Int64(time))
            chunk.nbt = .compound(fields)
            let file = folder.appendingPathComponent("r.0.0.mca")
            try Data(TestWorld.regionFile([chunk])).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let dimension = try #require(try World(contentsOf: worldURL).dimension("example:\(path)"))
            keys.insert(try #require(TileCache.key(for: region, regionFile: file)))
            fingerprints.insert(ScanCache.fingerprint([file, dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca")]))
            let directory = try #require(TileCache.directory(forWorldAt: worldURL, dimensionID: dimension.id, root: root))
            directories.insert(directory)
            let expectedPixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: region))
            referenceImages.insert(Data(expectedPixels))
            let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: directory), savesInBackground: false)
            for _ in 0..<2 {
                let tile = try #require(try await renderer.tile(for: region))
                #expect(tile.full.image.dataProvider?.data as Data? == Data(expectedPixels))
                let reader = RegionReader(dimension: dimension,
                                          cache: ScanCache(forWorldAt: worldURL, dimensionID: dimension.id, root: root))
                let times = await reader.inhabitedTimes(region)
                await reader.close()
                #expect(times.first == time)
            }
        }
        // Matching file metadata makes the dimension directory the only source of isolation.
        #expect(keys.count == 1 && fingerprints.count == 1)
        #expect(referenceImages.count == 3)
        #expect(directories.count == 3)
    }

    @Test func oldAmbiguousDirectoriesAreNotTrustedOrMigrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OldDimensionCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let world = URL(fileURLWithPath: "/tmp/Cache Identity World")
        let worldFolder = try #require(TileCache.worldFolder(forWorldAt: world, root: root))
        let oldDirectory = worldFolder.appendingPathComponent("example_ice_caves")
        let region = RegionPosition(x: 0, z: 0)
        let key = TileCache.Key(region: region, file: .init(size: 12_288, modified: 1_790_000_000), inputs: .init(context: .unknown, cutawayY: nil, style: .normal, heightScale: nil,
            blockFilter: MapBlockFilter(), colorSource: nil, gameSource: .unavailable,
            samplesNeighborBiomes: false, darkSpots: nil), biomeFiles: nil)
        TileCache(directory: oldDirectory).store(RegionTileRenderer.Canvas(), for: key)
        _ = try TestWorld.legacyCache([999], name: "inhabitedTimes.0.0.matching.v17",
                                      directory: oldDirectory.appendingPathComponent("scans"))
        for id in ["example:ice-caves", "example:ice_caves", "example:ice/caves"] {
            let directory = try #require(TileCache.directory(forWorldAt: world, dimensionID: id, root: root))
            #expect(directory.deletingLastPathComponent() == worldFolder)
            #expect(TileCache(directory: directory).load(key) == nil)
            let scans = ScanCache(forWorldAt: world, dimensionID: id, root: root)
            #expect(scans.directory == directory.appendingPathComponent("scans", isDirectory: true))
            #expect(!FileManager.default.fileExists(atPath: try #require(scans.directory).path))
            #expect(TileCache.directory(forWorldAt: world, dimensionID: id, root: root) == directory)
        }
        // Existing world-level pruning owns old files; selecting a dimension doesn't delete them.
        #expect(FileManager.default.fileExists(atPath: oldDirectory.path))
        let longID = "example:" + Array(repeating: "nested", count: 100).joined(separator: "/")
        let directory = try #require(TileCache.directory(forWorldAt: world, dimensionID: longID, root: root))
        #expect(directory.lastPathComponent.utf8.count <= 255)
        #expect(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld", root: nil) == nil)
    }
}
