import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct RegionFactsCacheTests {
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
        let reader = RegionReader(dimension: dimension, cache: cache) { dimension, region in
            _ = await count.note()
            return try await RegionReader.scan(dimension, region: region)
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
        let uncached = RegionReader(dimension: dimension, cache: .off) { dimension, region in
            _ = await count.note()
            return try await RegionReader.scan(dimension, region: region)
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
        let options = RegionReader.options(in: dimension.id)
        let key = ScanCache.Key(dimension: dimension, region: region, options: options)
        let facts = try dimension.scan(region: region, options: options)
        cache.store(facts, key: key)
        #expect(cache.load(key)?.containers.count == 1)
        for other in [RegionScanOptions(blockIDs: []), RegionScanOptions(blockIDs: options.blockIDs, biomeSampleY: 64),
                      RegionScanOptions(blockIDs: options.blockIDs, height: 384)] {
            #expect(cache.load(.init(dimension: dimension, region: region, options: other)) == nil)
        }
        let file = try #require(try FileManager.default.contentsOfDirectory(at: #require(cache.directory), includingPropertiesForKeys: nil).first)
        let compressed = try Data(contentsOf: file)
        let data = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let original = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for invalid in ["transform", "interpretation", "fingerprint", "dimension", "options"] {
            var entry = original
            var saved = try #require(entry["facts"] as? [String: Any])
            switch invalid {
            case "transform": entry["transformVersion"] = ScanCache.transformVersion - 1
            case "interpretation": saved["version"] = RegionFacts.interpretationVersion - 1
            case "fingerprint": entry["fingerprint"] = "different"
            case "dimension": saved["dimension"] = "minecraft:the_nether"
            default: saved["biomeSampleY"] = 64
            }
            entry["facts"] = saved
            let invalidData = try PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0)
            try ((invalidData as NSData).compressed(using: .lzfse) as Data).write(to: file)
            #expect(cache.load(key) == nil)
        }
        try compressed.write(to: file)
        #expect(cache.load(key)?.containers.count == 1)
    }

    @Test func failedReadsKeepPreviousIndexAndHeatUntilACompleteReplacementOrDeletion() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0), cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let reader = RegionReader(dimension: dimension, cache: cache)
        let initial = await DimensionIndex.read(reader, previous: nil, change: .all)
        let heat = await HeatMap.images(reader, previous: [:])
        #expect(initial.containers.count == 1 && heat.count == 1)
        let file = dimension.regionURL(at: region)
        try Data([0, 1]).write(to: file)
        for change in [RegionChange.all, .regions([region])] {
            let retained = await DimensionIndex.read(reader, previous: initial, change: change)
            #expect(retained.containers == initial.containers && retained.regions.count == 1)
        }
        #expect(await HeatMap.images(reader, previous: heat).count == 1)
        let badKey = ScanCache.Key(dimension: dimension, region: region, options: RegionReader.options(in: dimension.id))
        #expect(cache.load(badKey) == nil)
        // A successful empty region replaces old contributions; it is different from a failed read.
        try Data(repeating: 0, count: 8192).write(to: file)
        let empty = await DimensionIndex.read(reader, previous: initial, change: .all)
        #expect(empty.containers.isEmpty && empty.regions.count == 1)
        #expect(await HeatMap.images(reader, previous: heat).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(await DimensionIndex.read(reader, previous: initial, change: .all).regions.isEmpty)
        #expect(await HeatMap.images(reader, previous: heat).isEmpty)
        await reader.close()
    }

    @Test(.timeLimit(.minutes(1))) func aSaveDuringTheReadDoesNotPersistThatSnapshot() async throws {
        let url = try world()
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0), count = Reads(), gate = AsyncReadGate<Void>()
        let cache = ScanCache(directory: url.appendingPathComponent("test-cache"))
        let reader = RegionReader(dimension: dimension, cache: cache) { dimension, region in
            let facts = try await RegionReader.scan(dimension, region: region)
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
