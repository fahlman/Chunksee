import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import Chunksee

@Suite struct TileCacheTests {
    @Test func secondRenderComesFromTheCacheAndChangesInvalidateIt() async throws {
        let world = try TestWorld.make(chunks: [
            TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 },
        ])
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseeTileCache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionCoordinate(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: cacheDir), savesInBackground: false)
        let regionFile = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")

        let first = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(TileCache(directory: cacheDir).load(key) != nil)
        let second = try #require(try await renderer.tile(for: region))
        #expect(second.full.dataProvider?.data as Data? == first.full.dataProvider?.data as Data?)

        // Touching the region file (as the game does on save) makes a new key; the old entry is replaced.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: regionFile.path)
        let newKey = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(newKey != key)
        #expect(TileCache(directory: cacheDir).load(newKey) == nil)
        _ = try await renderer.tile(for: region)
        #expect(TileCache(directory: cacheDir).load(newKey) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count == 1)
    }
}

@Suite struct TileCachePruningTests {
    @Test func prunesLeastRecentlyUsedWorldsButKeepsTheOpenOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkseePrune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func world(_ name: String, bytes: Int, daysAgo: Double) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("overworld"), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: folder.appendingPathComponent("overworld/r.0.0.x"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: folder.path)
            return folder
        }
        let oldest = try world("a", bytes: 400, daysAgo: 30)
        let middle = try world("b", bytes: 400, daysAgo: 10)
        let open = try world("c", bytes: 400, daysAgo: 60)   // oldest, but it's the world being opened
        TileCache.prune(root: root, limit: 900, keeping: open)
        // A dimension's folder sits inside its world's folder, which sits directly in the root.
        let world = URL(fileURLWithPath: "/tmp/Some World")
        let worldFolder = try #require(TileCache.worldFolder(forWorldAt: world))
        #expect(worldFolder.deletingLastPathComponent().standardizedFileURL == TileCache.root?.standardizedFileURL)
        #expect(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld")?.deletingLastPathComponent().standardizedFileURL
                == worldFolder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: open.path))
    }
}

@Suite struct ScanCacheTests {
    @Test func previousStructureCacheIsRebuiltWithoutUnplacedMarkers() async throws {
        let world = try TestWorld.make(chunks: StructureTestWorld.chunks())
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionCoordinate(x: -1, z: 0)
        let cache = ScanCache(directory: world.appendingPathComponent("cache"))
        let fingerprint = ScanCache.fingerprint([
            dimension.regionDirectory.appendingPathComponent("r.-1.0.mca"),
            dimension.entitiesDirectory.appendingPathComponent("r.-1.0.mca"),
        ])
        let oldMarker = StructureMarker(StructureTests().start("minecraft:jungle_pyramid", chunk: (-17, 4), pieces: [
            ("minecraft:tejp", [-272, 64, 64, -261, 73, 78]),
        ]))
        let oldFile = try #require(cache.directory).appendingPathComponent("structures.-1.0.\(fingerprint).v3")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode([oldMarker])
        try ((data as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)
        let reader = RegionReader(dimension: dimension, cache: cache)
        #expect(await reader.structures(region).isEmpty)
        let saved: [StructureMarker]? = cache.load("structures", region: region, fingerprint: fingerprint)
        #expect(saved == [])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test func readsOnceAndAgainWhenASourceChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("r.0.0.mca")
        try Data([1, 2, 3]).write(to: source)
        let cache = ScanCache(directory: dir.appendingPathComponent("scans"))
        var reads = 0
        func value() -> [String] {
            cache.value("test", region: RegionCoordinate(x: 0, z: 0), sources: [source, dir.appendingPathComponent("missing.mca")]) {
                reads += 1
                return ["read \(reads)"]
            }
        }
        #expect(value() == ["read 1"] && value() == ["read 1"] && reads == 1)
        try Data([1, 2, 3, 4]).write(to: source)   // the game saved the region
        #expect(value() == ["read 2"] && value() == ["read 2"] && reads == 2)
        // Only the newest entry is kept.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scans").path).count == 1)
        var offReads = 0
        _ = ScanCache.off.value("test", region: RegionCoordinate(x: 0, z: 0), sources: [source]) { offReads += 1; return 0 }
        _ = ScanCache.off.value("test", region: RegionCoordinate(x: 0, z: 0), sources: [source]) { offReads += 1; return 0 }
        #expect(offReads == 2)
    }

    @Test func oneReadSavesEveryScansPart() async throws {
        let world = try TestWorld.make(chunks: (0..<2).flatMap { x in (0..<2).map { z in
            TestWorld.chunk(x: x, z: z, palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y == 0 ? 1 : 0 } } })
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let cache = ScanCache(directory: world.appendingPathComponent("cache"))
        // A whole-second date can be set back exactly; restoring a file's own date can come back a
        // microsecond off, which correctly counts as a change.
        let region = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: region.path)
        // One scan reads the region...
        let first = await BiomeScanner.scan(RegionReader(dimension: dimension, cache: cache))
        #expect(first.areas.map(\.chunkCount) == [4])
        // ...then blank its file but keep its size and date: only saved parts can still answer, and
        // the biome read saved the other scans' parts too.
        let size = (try FileManager.default.attributesOfItem(atPath: region.path)[.size] as? NSNumber)?.intValue ?? 0
        try Data(count: size).write(to: region)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: region.path)
        let reader = RegionReader(dimension: dimension, cache: cache)
        #expect(await BiomeScanner.scan(reader).areas.map(\.chunkCount) == [4])
        #expect(await reader.inhabitedTimes(RegionCoordinate(x: 0, z: 0)).count == 1024)
        #expect(await reader.biomes(RegionCoordinate(x: 0, z: 0)).count == 4)
        #expect(await BiomeScanner.scan(RegionReader(dimension: dimension, cache: .off)).areas.isEmpty)
    }
}

@Suite struct CacheRootTests {
    @Test(.timeLimit(.minutes(1))) func closingWaitsForStartupMaintenanceBeforeCacheCleanup() async throws {
        let world = try TestWorld.make(chunks: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheRootTests-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: root)
        }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID())")!
        let gate = AsyncReadGate<Void>()
        let resources = WorldResources(snapshot: try await WorldSnapshot.read(world), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root,
                                       maintainCache: { _, folder in
            await gate.read("maintenance")
            // A disk operation already underway can still finish after cancellation.
            TileCache.markUsed(worldFolder: folder)
        })
        await gate.waitForRequest("maintenance")
        await resources.index.waitForIndex()
        var finishedClosing = false
        let closing = Task {
            resources.close()
            await resources.waitUntilClosed()
            finishedClosing = true
        }
        await gate.waitForCancellation("maintenance")
        #expect(resources.isClosed && !finishedClosing)
        await gate.finish("maintenance", with: ())
        await closing.value
        #expect(finishedClosing && FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.removeItem(at: root)
        await resources.waitUntilClosed()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func sessionsCacheOnlyUnderTheirRoot() async throws {
        let world = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheRootTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: root)
        }
        let defaults = UserDefaults(suiteName: "ChunkseeTests-\(UUID().uuidString)")!
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: root)
        await session.search.waitForIndex()
        session.close()
        // Its background cache writes must finish before the deferred cleanup removes `root`.
        await session.waitUntilClosed()
        let scans = try #require(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld", root: root))
            .appendingPathComponent("scans")
        #expect(FileManager.default.fileExists(atPath: scans.path))
        // Nothing for this world in the app's own Caches folder.
        let appFolder = try #require(TileCache.worldFolder(forWorldAt: world))
        #expect(!FileManager.default.fileExists(atPath: appFolder.path))
    }
}

@Suite(.timeLimit(.minutes(1))) struct TileCacheWriteLifecycleTests {
    private final class Fixture {
        let url: URL
        let gate = AsyncReadGate<Void>()
        var maps: [MapModel] = []
        var cache: URL { url.appendingPathComponent("test-cache") }

        init() throws {
            url = try TestWorld.make(chunks: [TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }])
        }

        func dimension() throws -> ChunkseeKit.Dimension { try #require(try World(contentsOf: url).dimension("overworld")) }
        func close() async {
            maps.forEach { $0.close() }
            await gate.finishAll(with: ())
            for map in maps { await map.waitForRenders() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func visibleTilesDoNotWaitForCacheButClosingDoes() async throws {
        try await withFixture { f in
            let gate = f.gate, dimension = try f.dimension()
            let map = MapModel(dimension: dimension, center: CGPoint(x: 8, y: 8), cacheDirectory: f.cache, writeCache: { operation in
                // Represent an already-started disk operation that completes despite cancellation.
                await gate.read("write")
                await operation.store()
            })
            f.maps.append(map)
            map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
            await gate.waitForRequest("write")
            await map.waitUntilIdle()
            #expect(map.tiles.count == 1 && map.unfinishedCacheWrites == 1)
            #expect(!FileManager.default.fileExists(atPath: f.cache.path))
            var finished = false
            let closing = Task { map.close(); await map.waitForRenders(); finished = true }
            await gate.waitForCancellation("write")
            #expect(!finished)
            await gate.finish("write", with: ())
            await closing.value
            #expect(finished && map.unfinishedCacheWrites == 0)
            let key = try #require(TileCache.key(for: RegionCoordinate(x: 0, z: 0), regionFile: dimension.regionDirectory.appendingPathComponent("r.0.0.mca")))
            let bytes = try #require(map.tiles[RegionCoordinate(x: 0, z: 0)]?.dataProvider?.data as Data?)
            #expect(TileCache(directory: f.cache).load(key) == Array(bytes))
            try FileManager.default.removeItem(at: f.cache)
            #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        }
    }

    @Test func aDroppedRenderNeverSchedulesItsCacheWrite() async throws {
        try await withFixture { f in
            let gate = f.gate, count = WriteCount()
            let map = MapModel(dimension: try f.dimension(), center: CGPoint(x: 8, y: 8), cacheDirectory: f.cache,
                writeCache: { operation in await count.note(); await operation.store() }, renderTile: { renderer, region in
                    let tile = try await renderer.tile(for: region)
                    await gate.read("render")
                    return tile
                })
            f.maps.append(map)
            map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
            await gate.waitForRequest("render")
            map.cancel()
            await gate.waitForCancellation("render")
            await gate.finish("render", with: ())
            await map.waitForRenders()
            #expect(await count.value == 0)
            #expect(map.tiles.isEmpty && map.unfinishedCacheWrites == 0)
            #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        }
    }

    private actor WriteCount {
        private(set) var value = 0
        func note() { value += 1 }
    }
}
