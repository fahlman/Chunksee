import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct TileCacheTests {
    @Test func sharedKeyPrimitivesKeepDiskNamesAndReadFreshFileAttributes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheKeyTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = URL(fileURLWithPath: "/Worlds/A folder/../München")
        #expect(TileCache.worldFolder(forWorldAt: world, root: root)?.lastPathComponent == "308b90831c3d6a14")
        #expect(TileCache.worldFolder(forWorldAt: world, root: nil) == nil)

        let file = root.appendingPathComponent("r.-1.2.mca"), missing = root.appendingPathComponent("missing.mca")
        let region = RegionPosition(x: -1, z: 2)
        let date = Date(timeIntervalSince1970: 1_790_000_000.5)
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        // Prime Foundation's URL metadata before changing this same URL's file.
        _ = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let original = try #require(TileCache.key(for: region, regionFile: file))
        #expect(original.fileName == "r.-1.2.normal.surface.all.ordinary.fallback.hunknown.cnone.3.1790000000500000.v29.lzfse")
        #expect(TileCache.key(for: region, regionFile: file, cutawayY: -16)?.fileName
                == "r.-1.2.normal.cutaway.all.ordinary.fallback.y-16.3.1790000000500000.v29.lzfse")
        #expect(ScanCache.fingerprint([file, missing]) == "573ac917b6c1e815")
        #expect(ScanCache.fingerprint([missing, file]) != ScanCache.fingerprint([file, missing]))

        try Data([1, 2, 3, 4]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let resized = try #require(TileCache.key(for: region, regionFile: file))
        #expect(resized.fileSize == 4 && resized.modified == original.modified)
        #expect(ScanCache.fingerprint([file, missing]) == "c5830d16238e6a68")

        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: file.path)
        let touched = try #require(TileCache.key(for: region, regionFile: file))
        #expect(touched.fileSize == 4 && touched.modified == original.modified + 1_000_000)
        #expect(ScanCache.fingerprint([file, missing]) == "d789b310e6f2543d")
        try FileManager.default.removeItem(at: file)
        #expect(TileCache.key(for: region, regionFile: file) == nil)
        #expect(ScanCache.fingerprint([file, missing]) == "8c8a4f8e0f4479e5")
    }

    @Test func oldTilesAreRebuiltByScanningBlocksWhenHeightmapWidthIsAmbiguous() async throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:grass_block"]) { _, y, _ in
            y == 10 ? 1 : 0
        }
        // A 4000-block-high dimension starting at -2032: first free Y 11 is stored as 2043.
        // Both 11-bit and 12-bit maps occupy 52 longs, so their length cannot choose a width.
        var packed = [UInt64](repeating: 0, count: 52)
        for i in 0..<256 { packed[i / 5] |= UInt64(2043) << UInt64(i % 5 * 12) }
        spec.nbt = .compound(try #require(spec.nbt.compound).merging([
            "yPos": .int(-127),
            "Heightmaps": .compound(["WORLD_SURFACE": .longArray(packed.map { Int64(bitPattern: $0) })]),
        ]) { $1 })
        let world = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let cache = TileCache(directory: world.appendingPathComponent("test-cache"))
        let key = try #require(TileCache.key(for: region, regionFile: dimension.regionDirectory.appendingPathComponent("r.0.0.mca")))
        let oldFile = cache.directory.appendingPathComponent("r.0.0.surface.\(key.fileSize).\(key.modified).v6.lzfse")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let stale = Data(repeating: 0, count: RegionTileRenderer.side * RegionTileRenderer.side * 4)
        try ((stale as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)

        let renderer = RegionTileRenderer(dimension: dimension, cache: cache, savesInBackground: false)
        let tile = try #require(try await renderer.tile(for: region))
        let pixels = try #require(tile.full.image.dataProvider?.data as Data?)
        let offset = (RegionTileRenderer.side + 1) * 4
        let grass = try #require(BlockColors.color(for: "minecraft:grass_block"))
        #expect(Array(pixels[offset..<offset + 4]) == [grass.red, grass.green, grass.blue, 255])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(cache.load(key)?.pixels == Array(pixels))
    }

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
        let region = RegionPosition(x: 0, z: 0)
        let renderer = RegionTileRenderer(dimension: dimension, cache: TileCache(directory: cacheDir), savesInBackground: false)
        let regionFile = dimension.regionDirectory.appendingPathComponent("r.0.0.mca")

        let first = try #require(try await renderer.tile(for: region))
        let key = try #require(TileCache.key(for: region, regionFile: regionFile))
        #expect(TileCache(directory: cacheDir).load(key) != nil)
        let second = try #require(try await renderer.tile(for: region))
        #expect(second.full.image.dataProvider?.data as Data? == first.full.image.dataProvider?.data as Data?)

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

@Suite(.isolatedStores) struct TileCachePruningTests {
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
        let worldFolder = try #require(TileCache.worldFolder(forWorldAt: world, root: root))
        #expect(worldFolder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld", root: root)?.deletingLastPathComponent().standardizedFileURL
                == worldFolder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: open.path))
    }
}

@Suite(.isolatedStores) struct ScanCacheTests {
    @Test(arguments: [13, 15]) func oldCreatureCacheIsRereadWithTheEntityChunksHealthDefaults(version: Int) async throws {
        let world = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let entitiesFile = dimension.entitiesDirectory.appendingPathComponent("r.0.0.mca")
        let entity = Fixtures.mob([
            "id": .string("minecraft:cat"), "Health": .float(6), "Owner": .intArray([1, 2, 3, 4]),
            "Pos": .list([.double(4), .double(64), .double(4)]),
        ])
        let chunk = NBT.compound(["DataVersion": .int(4786), "Entities": .list([entity])])
        try FileManager.default.createDirectory(at: dimension.entitiesDirectory, withIntermediateDirectories: true)
        try Data(TestWorld.regionFile([.init(x: 0, z: 0, nbt: chunk)])).write(to: entitiesFile)
        let cache = ScanCache(directory: world.appendingPathComponent("test-cache"))
        let fingerprint = ScanCache.fingerprint([dimension.regionDirectory.appendingPathComponent("r.0.0.mca"), entitiesFile])
        let oldFile = try #require(cache.directory).appendingPathComponent("creatures.0.0.\(fingerprint).v\(version)")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = [Creature(id: "minecraft:cat", x: 4, y: 64, z: 4, owner: NBT.intArray([1, 2, 3, 4]).uuid, health: 6)]
        let encoded = try PropertyListEncoder().encode(stale)
        try ((encoded as NSData).compressed(using: .lzfse) as Data).write(to: oldFile)

        let reader = RegionReader(dimension: dimension, cache: cache)
        let creatures = try #require(await reader.facts(region)).creatures
        #expect(creatures.count == 1 && creatures.first?.health == 6 && creatures.first?.maxHealth == 10)
        let saved = cache.load(.init(dimension: dimension, region: region, options: RegionReader.options()))?.creatures
        #expect(saved?.first?.maxHealth == 10)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test func previousStructureCacheIsRebuiltWithoutUnplacedMarkers() async throws {
        let world = try TestWorld.make(chunks: StructureTestWorld.chunks())
        defer { try? FileManager.default.removeItem(at: world) }
        let dimension = try #require(try World(contentsOf: world).dimension("overworld"))
        let region = RegionPosition(x: -1, z: 0)
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
        let index = await TestWorld.index(reader)
        let rebuilt = try #require(index.regions[region])
        #expect(rebuilt.structures.isEmpty)
        let saved = cache.load(.init(dimension: dimension, region: region, options: RegionReader.options()))?.structures.map { StructureMarker($0) }
        #expect(saved == [])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test func oneEnvelopeServesEveryScan() async throws {
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
        let first = await TestWorld.index(RegionReader(dimension: dimension, cache: cache))
        #expect(first.biomeAreas.map(\.chunkCount) == [4])
        // ...then blank its file but keep its size and date: only the saved envelope can still answer.
        let size = (try FileManager.default.attributesOfItem(atPath: region.path)[.size] as? NSNumber)?.intValue ?? 0
        try Data(count: size).write(to: region)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: region.path)
        let reader = RegionReader(dimension: dimension, cache: cache)
        #expect(await TestWorld.index(reader).biomeAreas.map(\.chunkCount) == [4])
        #expect(await reader.inhabitedTimes(RegionPosition(x: 0, z: 0)).count == 1024)
        #expect(await TestWorld.index(reader).biomes.count == 4)
        #expect(await TestWorld.index(RegionReader(dimension: dimension, cache: .off)).biomeAreas.isEmpty)
    }
}

@Suite(.isolatedStores) struct CacheRootTests {
    nonisolated private static func finishMaintenance(at folder: URL) {
        #expect(!Thread.isMainThread)
        TileCache.markUsed(worldFolder: folder)
    }

    @Test(.timeLimit(.minutes(1))) func closingWaitsForStartupMaintenanceBeforeCacheCleanup() async throws {
        let world = try TestWorld.make(chunks: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheRootTests-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: world)
            try? FileManager.default.removeItem(at: root)
        }
        let defaults = TestDefaults.make()
        let gate = AsyncReadGate<Void>()
        let resources = try WorldResources(snapshot: try await WorldSnapshot.read(world), names: PlayerNames(defaults: defaults),
                                       savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: root,
                                       maintainCache: { _, folder in
            await gate.read("maintenance")
            // A disk operation already underway can still finish after cancellation.
            Self.finishMaintenance(at: folder)
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
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(world, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: root)
        await session.search.waitForIndex()
        session.close()
        // Its background cache writes must finish before the deferred cleanup removes `root`.
        await session.waitUntilClosed()
        let scans = try #require(TileCache.directory(forWorldAt: world, dimensionID: "minecraft:overworld", root: root))
            .appendingPathComponent("scans")
        #expect(FileManager.default.fileExists(atPath: scans.path))
        // Verify the session's writes without consulting the real app's cache at all.
        let worldFolder = try #require(TileCache.worldFolder(forWorldAt: world, root: root))
        #expect(worldFolder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [worldFolder.lastPathComponent])
    }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct TileCacheWriteLifecycleTests {
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

    @Test(arguments: [false, true]) func visibleTilesDoNotWaitForCacheButClosingDoes(closeOwner: Bool) async throws {
        try await withFixture { f in
            let gate = f.gate, dimension = try f.dimension(), work = BackgroundWork()
            let map = MapModel(work: work, dimension: dimension, center: CGPoint(x: 8, y: 8), cacheDirectory: f.cache, writeCache: { operation in
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
            let closing = Task {
                if closeOwner { work.close() } else { map.close() }
                await map.waitForRenders()
                finished = true
            }
            await gate.waitForCancellation("write")
            #expect(!finished)
            await gate.finish("write", with: ())
            await closing.value
            #expect(finished && map.unfinishedCacheWrites == 0)
            let key = try #require(TileCache.key(for: RegionPosition(x: 0, z: 0), regionFile: dimension.regionDirectory.appendingPathComponent("r.0.0.mca")))
            let bytes = try #require(map.tiles[RegionPosition(x: 0, z: 0)]?.image.dataProvider?.data as Data?)
            #expect(TileCache(directory: f.cache).load(key)?.pixels == Array(bytes))
            try FileManager.default.removeItem(at: f.cache)
            #expect(!FileManager.default.fileExists(atPath: f.cache.path))
        }
    }

    @Test func aDroppedRenderNeverSchedulesItsCacheWrite() async throws {
        try await withFixture { f in
            let gate = f.gate, count = WriteCount()
            let map = MapModel(work: BackgroundWork(), dimension: try f.dimension(), center: CGPoint(x: 8, y: 8), cacheDirectory: f.cache,
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
