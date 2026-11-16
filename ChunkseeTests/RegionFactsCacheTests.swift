import ChunkseeKit
import ChunkseeKitTestSupport
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct RegionFactsCacheTests {
    @Test func biomeAreasUseActualSurfaceAndOmitEmptyColumnsWithoutHeightmaps() async throws {
        var blocks = [Int](repeating: 0, count: 4096)
        blocks[ChunkSection.blockIndex(x: 8, y: 1, z: 8)] = 1
        let ground = Fixtures.section(y: 0, palette: [.string("air"), .string("stone")], indices: blocks,
                                      biomes: ["minecraft:plains", "minecraft:desert"],
                                      biomeIndices: (0..<64).map { $0 < 16 ? 1 : 0 })
        let unusedStone = Fixtures.section(y: 1, palette: [.string("air"), .string("stone")],
                                          indices: [Int](repeating: 0, count: 4096), biomes: ["minecraft:snowy_taiga"])
        blocks[ChunkSection.blockIndex(x: 8, y: 1, z: 8)] = 0
        blocks[0] = 1
        let neighbor = Fixtures.section(y: 0, palette: [.string("air"), .string("stone")],
                                        indices: blocks, biomes: ["minecraft:plains"])
        let chunks = [[ground, unusedStone], [neighbor], [unusedStone]].enumerated().map { index, sections in
            TestWorld.ChunkSpec(x: index, z: 0, nbt: Fixtures.chunk(x: index, z: 0,
                dataVersion: SaveVersion.java26_3, sections: sections, extra: ["yPos": .int(0)]))
        }
        let url = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("minecraft:overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let scan = await TestWorld.index(reader)
        #expect(scan.biomes == [ChunkPosition(x: 0, z: 0): "minecraft:desert"])
        #expect(scan.biomeAreas.count == 1 && scan.biomeAreas.first?.group.id == "minecraft:desert")
        #expect(scan.biomeAreas.first?.chunkCount == 1)
        await reader.close()
    }

    private actor Reads {
        var count = 0
        func note() -> Int { count += 1; return count }
    }

    private func world() throws -> URL {
        var chunk = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:stone"]) { _, _, _ in 0 }
        var fields = try #require(chunk.nbt.compound)
        fields["InhabitedTime"] = .long(7200)
        fields["block_entities"] = .list([.compound([
            "id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
            "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(2)])]),
        ])])
        chunk.nbt = .compound(fields)
        return try TestWorld.make(chunks: [chunk])
    }

    @Test func oneScanServesConcurrentConsumersAndEachOfTheThreeSourcesInvalidates() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0), count = Reads()
        let cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let reader = RegionReader(dimension: dimension, cache: cache) { dimension, region, options in
            _ = await count.note()
            return try await RegionReader.scan(dimension, region: region, options: options)
        }
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { await reader.facts(region)?.containers.count ?? -1 } }
            for await value in group { #expect(value == 1) }
        }
        #expect(await count.count == 1)
        var expectedReads = 1
        for folder in ChunkseeKit.Dimension.Folder.allCases {
            let file = dimension.regionURL(folder, at: region)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = (try? Data(contentsOf: file)) ?? Data(repeating: 0, count: 8192)
            bytes.append(0) // A valid region with changed size; timestamp precision cannot hide this save.
            try bytes.write(to: file)
            #expect(await reader.facts(region) != nil)
            #expect(await reader.facts(region) != nil)
            expectedReads += 1
            #expect(await count.count == expectedReads)
            #expect(try FileManager.default.contentsOfDirectory(atPath: #require(cache.directory).path).count == 1)
        }
        // Removing a formerly present POI file is also a new source state.
        try FileManager.default.removeItem(at: dimension.regionURL(.pointsOfInterest, at: region))
        #expect(await reader.facts(region) != nil)
        #expect(await count.count == expectedReads + 1)
        await reader.close()
        let uncached = RegionReader(dimension: dimension, cache: .off) { dimension, region, options in
            _ = await count.note()
            return try await RegionReader.scan(dimension, region: region, options: options)
        }
        _ = await uncached.facts(region); _ = await uncached.facts(region)
        #expect(await count.count == expectedReads + 3)
        await uncached.close()
    }

    @Test func optionsIdentityAndBothVersionsAreValidated() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let options = RegionReader.options()
        let key = ScanCache.Key(dimension: dimension, region: region, options: .init(options))
        let facts = try dimension.scan(region: region, options: options)
        cache.store(facts, key: key)
        #expect(cache.load(key)?.containers.count == 1)
        var empty = options, all = options, sample = options, height = options, pieces = options
        empty.biomeIDs = []; all.biomeIDs = nil; sample.biomeSampleY = 64; height.height = 384; pieces.structurePieceIDs = nil
        for other in [empty, all, sample, height, pieces] {
            #expect(cache.load(.init(dimension: dimension, region: region, options: .init(other))) == nil)
        }
        let directory = try #require(cache.directory)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let compressed = try Data(contentsOf: file)
        let original = try CacheArchiveFixture.read(file, as: RegionFacts.self)
        for invalid in ["storage", "interpretation", "identity", "dimension", "options"] {
            var entry = original
            switch invalid {
            case "storage":
                entry.storageVersion = -1
                try CacheArchiveFixture.write(entry, to: file)
            case "identity":
                entry.identity = "different"
                try CacheArchiveFixture.write(entry, to: file)
            default:
                try CacheArchiveFixture.corruptPayload(entry, to: file) { saved in
                    switch invalid {
                    case "interpretation":
                        var version = try #require(saved["version"] as? [String: Any])
                        version["revision"] = -1
                        saved["version"] = version
                    case "dimension": saved["dimension"] = "minecraft:the_nether"
                    default: saved["biomeSampleY"] = 64
                    }
                }
            }
            #expect(cache.load(key) == nil)
        }
        try compressed.write(to: file)
        #expect(cache.load(key)?.containers.count == 1)
        var transformed = key
        transformed.transform += 1
        #expect(cache.load(transformed) == nil)
    }

    @Test func cachePreservesIntegerLimitsAndNonfiniteSavedNumbers() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let components = NBT.compound([
            "minimum": .long(.min), "maximum": .long(.max),
            "infinite": .double(.infinity), "negativeInfinite": .float(-.infinity), "notANumber": .double(.nan),
        ])
        let facts = try TestWorld.facts(blockEntities: [.compound([
            "id": .string("minecraft:chest"), "x": .int(0), "y": .int(64), "z": .int(0),
            "Items": .list([.compound(["id": .string("minecraft:diamond"), "count": .int(1), "components": components])]),
        ])])
        let key = ScanCache.Key(dimension: dimension, region: .init(x: 0, z: 0), options: .init(facts.options))
        let cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        cache.store(facts, key: key)
        let loaded = try #require(cache.load(key)?.containers.first?.items.first)
        let expected = ItemStack(id: "minecraft:diamond", components: components)
        // Compare the public persistence contract, including NBT's exact binary numbers.
        // Sorted keys make the encoding independent of dictionary iteration order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(loaded) == encoder.encode(expected))
    }

    @Test func failedReadsKeepPreviousIndexAndHeatUntilACompleteReplacementOrDeletion() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0), cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let reader = RegionReader(dimension: dimension, cache: cache)
        let initial = await DimensionContent.read(reader, previous: nil, change: .all)
        let heat = await HeatMap.images(reader, previous: [:])
        #expect(initial.containers.count == 1 && heat.count == 1)
        let file = dimension.regionURL(at: region)
        try Data([0, 1]).write(to: file)
        for change in [RegionChange.all, .regions([region])] {
            let retained = await DimensionContent.read(reader, previous: initial, change: change)
            #expect(retained.containers == initial.containers && retained.regions.count == 1)
        }
        #expect(await HeatMap.images(reader, previous: heat).count == 1)
        let badKey = ScanCache.Key(dimension: dimension, region: region, options: .init(RegionReader.options()))
        #expect(cache.load(badKey) == nil)
        // A successful empty region replaces old contributions; it is different from a failed read.
        try Data(repeating: 0, count: 8192).write(to: file)
        let empty = await DimensionContent.read(reader, previous: initial, change: .all)
        #expect(empty.containers.isEmpty && empty.regions.count == 1)
        #expect(await HeatMap.images(reader, previous: heat).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(await DimensionContent.read(reader, previous: initial, change: .all).regions.isEmpty)
        #expect(await HeatMap.images(reader, previous: heat).isEmpty)
        await reader.close()
    }

    @Test(arguments: ChunkseeKit.Dimension.Folder.allCases)
    func failedFolderDiscoveryRetainsTheIndexAndHeat(folder: ChunkseeKit.Dimension.Folder) async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let directory = dimension.directory(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reader = RegionReader(dimension: dimension, cache: .off)
        let initial = await DimensionContent.read(reader, previous: nil, change: .all)
        let heat = await HeatMap.images(reader, previous: [:])
        #expect(initial.containers.count == 1 && heat.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        for change in [RegionChange.all, .regions([.init(x: 0, z: 0)])] {
            let retained = await DimensionContent.read(reader, previous: initial, change: change)
            #expect(retained.containers == initial.containers && retained.storage == initial.storage)
            #expect(Set(retained.regions.keys) == Set(initial.regions.keys))
        }
        #expect(await HeatMap.images(reader, previous: heat).count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let recovered = await DimensionContent.read(reader, previous: initial, change: .all)
        #expect(recovered.containers == initial.containers)
        // Actual terrain-folder removal, unlike failed discovery, removes its contributions.
        try FileManager.default.removeItem(at: dimension.regionDirectory)
        #expect(await DimensionContent.read(reader, previous: recovered, change: .all).regions.isEmpty)
        #expect(await HeatMap.images(reader, previous: heat).isEmpty)
        await reader.close()
    }

    @Test(.timeLimit(.minutes(1))) func aSaveDuringTheReadDoesNotPersistThatSnapshot() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0), count = Reads(), gate = AsyncReadGate<Void>()
        let cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let reader = RegionReader(dimension: dimension, cache: cache) { dimension, region, options in
            let facts = try await RegionReader.scan(dimension, region: region, options: options)
            if await count.note() == 1 { await gate.read("read") }
            return facts
        }
        let pending = Task { await reader.facts(region) }
        await gate.waitForRequest("read")
        let file = dimension.regionURL(at: region)
        var bytes = try Data(contentsOf: file); bytes.append(0); try bytes.write(to: file)
        await gate.finish("read", with: ())
        #expect(await pending.value?.containers.count == 1)
        #expect(!FileManager.default.fileExists(atPath: try #require(cache.directory).path))
        #expect(await reader.facts(region)?.containers.count == 1)
        #expect(await count.count == 2)
        await reader.close()
    }
}
