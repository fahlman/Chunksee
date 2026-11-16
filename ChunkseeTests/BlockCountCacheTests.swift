import ChunkseeIndex
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BlockCountCacheTests {
    @Test func coverageAndTerrainIdentitySurviveReopenAndRejectLateWrites() throws {
        let root = try TestWorld.make(chunks: [BlockSearchFixture.chunk(x: 0, count: 7)])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let region = RegionPosition(x: 0, z: 0)
        let ids: Set<String> = ["minecraft:diamond_ore", "minecraft:gold_ore"]
        let key = BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids)
        let counts = try dimension.countBlocks(region: region, matching: ids)
        let cache = BlockCountCache(world: root, dimensionID: dimension.id, root: root.appendingPathComponent("cache"))
        cache.store(counts, key: key)
        let reopened = BlockCountCache(world: root, dimensionID: dimension.id, root: root.appendingPathComponent("cache"))
        #expect(reopened.load(key) == counts)
        #expect(reopened.load(.init(dimension: dimension, region: region, blockIDs: ["minecraft:diamond_ore"])) == counts)
        #expect(reopened.load(.init(dimension: dimension, region: region, blockIDs: ids.union(["minecraft:iron_ore"]))) == nil)

        for kind in [ChunkseeKit.Dimension.Folder.entities, .pointsOfInterest] {
            let file = dimension.regionURL(kind, at: region)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: file)
        }
        #expect(BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids) == key)
        #expect(reopened.load(key) == counts)

        let replacement = try TestWorld.regionFile([BlockSearchFixture.chunk(x: 0, count: 11)])
        try Data(replacement).write(to: dimension.regionURL(.terrain, at: region), options: .atomic)
        let newer = BlockCountCache.Key(dimension: dimension, region: region, blockIDs: ids)
        #expect(newer != key)
        #expect(reopened.load(newer) == nil)
        let updated = try dimension.countBlocks(region: region, matching: ids)
        cache.store(updated, key: newer)
        cache.store(counts, key: key) // An older job wins the slot, but cannot masquerade as current.
        #expect(reopened.load(newer) == nil)
        cache.store(updated, key: newer)
        #expect(reopened.load(newer) == updated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: #require(cache.directory).path).count == 1)
    }

    @Test func damagedEnvelopeAndInterpretationAreCacheMisses() throws {
        let root = try TestWorld.make(chunks: [BlockSearchFixture.chunk(x: 0, count: 3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("overworld"))
        let key = BlockCountCache.Key(dimension: dimension, region: .init(x: 0, z: 0), blockIDs: ["minecraft:diamond_ore"])
        let counts = try dimension.countBlocks(region: key.region, matching: Set(key.blockIDs))
        let cache = BlockCountCache(world: root, dimensionID: dimension.id, root: root.appendingPathComponent("cache"))
        cache.store(counts, key: key)
        let file = try #require(cache.directory).appendingPathComponent("counts.0.0.plist.lzfse")
        let entry = try CacheArchiveFixture.read(file)
        for field in ["identity", "storageVersion"] {
            var broken = entry
            broken[field] = field == "identity" ? "wrong" : 99
            try CacheArchiveFixture.write(broken, to: file)
            #expect(cache.load(key) == nil)
        }
        cache.store(counts, key: key)
        var changed = key
        changed.interpretation = try CacheArchiveFixture.changing(key.interpretation, field: "revision")
        #expect(cache.load(changed) == nil)
        #expect(cache.load(key) == counts)
    }
}
