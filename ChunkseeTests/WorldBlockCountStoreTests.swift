import ChunkseeIndex
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

actor BlockReadLog {
    struct Call: Sendable { let region: RegionPosition; let ids: Set<String> }
    private(set) var calls: [Call] = []
    func record(_ region: RegionPosition, _ ids: Set<String>) { calls.append(Call(region: region, ids: ids)) }
}

/// The same store/query owners used by windows, with real synthetic terrain and no native UI.
final class BlockCountHarness {
    let root: URL
    let world: World
    let dimension: ChunkseeKit.Dimension
    let work = BackgroundWork()
    let players = PlayerRoster([])
    let index: WorldIndexStore
    let counts: WorldBlockCountStore
    let saved: SavedSearches
    private let names: PlayerNames
    private let execute: WorldQueryStore.Read
    private var queryStore: WorldQueryStore?
    var queries: WorldQueryStore {
        if let queryStore { return queryStore }
        let store = WorldQueryStore(index: index, work: work, names: names, savedSearches: saved,
            singleplayerUUID: { nil }, gameNames: { .unavailable }, blockCounts: counts, execute: execute)
        queryStore = store
        return store
    }

    init(chunks: [TestWorld.ChunkSpec], read: @escaping WorldBlockCountStore.Read = WorldBlockCountStore.count,
         execute: @escaping WorldQueryStore.Read = WorldSearch.execute) throws {
        root = try TestWorld.make(chunks: chunks)
        world = try World(contentsOf: root)
        dimension = try #require(world.dimension("overworld"))
        let catalog = try WorldDefinitions.read(world, assets: nil).notableBlocks
        index = WorldIndexStore(readers: [], work: work, firstDimension: dimension.id, playerRoster: players)
        counts = WorldBlockCountStore(world: WorldReadSource(world), dimensions: [dimension], catalog: catalog,
            cacheRoot: nil, cachePreparation: nil, index: index, work: work, read: read)
        let defaults = TestDefaults.make()
        saved = SavedSearches(defaults: defaults)
        names = PlayerNames(defaults: defaults)
        self.execute = execute
    }

    func point(_ x: Double) throws -> BlockSearchPoint {
        .init(dimension: dimension.id, origin: try #require(BlockSearchOrigin(x: x, z: 8)))
    }

    func catalog(ores: [String]) throws -> NotableBlock.Catalog {
        let file = root.appendingPathComponent("datapacks/ChunkseeTest/data/minecraft/tags/block/ores.json")
        try JSONSerialization.data(withJSONObject: ["replace": true, "values": ores]).write(to: file, options: .atomic)
        return try WorldDefinitions.read(world, assets: nil).notableBlocks
    }

    func close() { queryStore?.close(); counts.close(); index.cancel(); work.close() }
    func finish() async { await work.waitUntilFinished() }
}

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct WorldBlockCountStoreTests {
    @Test func ordinaryIndexFinishesBeforeTerrainCountingStarts() async throws {
        let root = try TestWorld.make(chunks: [BlockSearchFixture.chunk(x: 0, count: 5)])
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(contentsOf: root), dimension = try #require(world.dimension("overworld"))
        let reader = RegionReader(dimension: dimension, cache: .off)
        let content = await DimensionContent.read(reader, previous: nil, change: .all)
        let work = BackgroundWork(), gate = AsyncReadGate<DimensionContent>(), log = BlockReadLog()
        let index = WorldIndexStore(readers: [reader], work: work, firstDimension: dimension.id, playerRoster: PlayerRoster([]),
            readDimension: { _, _, _ in await gate.read("index") })
        let catalog = try WorldDefinitions.read(world, assets: nil).notableBlocks
        let store = WorldBlockCountStore(world: WorldReadSource(world), dimensions: [dimension], catalog: catalog,
            cacheRoot: nil, cachePreparation: nil, index: index, work: work,
            read: { dimension, region, ids in
                await log.record(region, ids)
                return try await WorldBlockCountStore.count(dimension, region: region, blockIDs: ids)
            })
        defer { store.close(); index.cancel(); work.close() }
        store.setDemand([.init(dimension: dimension.id, origin: try #require(BlockSearchOrigin(x: 8, z: 8)))])
        await gate.waitForRequest("index")
        #expect(store.isReading && index.isIndexing)
        #expect(await log.calls.isEmpty)
        await gate.finish("index", with: content)
        await store.waitForCounts()
        #expect(!index.isIndexing)
        #expect(await log.calls.map(\.region) == [.init(x: 0, z: 0)])
        store.close(); index.cancel(); work.close(); await work.waitUntilFinished()
    }

    @Test func outwardCountsReuseRegroupedIDsAndIgnoreEntityAndPOIEdits() async throws {
        let log = BlockReadLog()
        let h = try BlockCountHarness(chunks: [0, 32, 96].map { BlockSearchFixture.chunk(x: $0, count: 3) },
            read: { dimension, region, ids in
                await log.record(region, ids)
                return try await WorldBlockCountStore.count(dimension, region: region, blockIDs: ids)
            })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        h.counts.setDemand([try h.point(520)])
        await h.counts.waitForCounts()
        #expect(await log.calls.map(\.region.x) == [1, 0, 3])
        let original = h.counts.snapshot
        let regrouped = try h.catalog(ores: ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"])
        #expect(regrouped.blockIDs == h.counts.catalog.blockIDs)
        h.counts.setCatalog(regrouped)
        await h.counts.waitForCounts()
        #expect(h.counts.snapshot === original)
        #expect(await log.calls.count == 3)

        for folder in [ChunkseeKit.Dimension.Folder.entities, .pointsOfInterest] {
            let file = h.dimension.regionURL(folder, at: .init(x: 1, z: 0))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        h.index.rebuild(firstDimension: h.dimension.id)
        await h.index.waitForIndex()
        await h.counts.waitForCounts()
        #expect(await log.calls.count == 3)

        let expanded = try h.catalog(ores: ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore", "minecraft:gold_ore"])
        h.counts.setCatalog(expanded)
        await h.counts.waitForCounts()
        #expect(await log.calls.count == 6)
        let counts = try #require(h.counts.snapshot.dimensions[h.dimension.id])
        for x in [0, 1, 3] {
            let position = RegionPosition(x: x, z: 0)
            #expect(counts.coverage(of: position, matching: expanded.blockIDs) == .complete)
            #expect(counts.regions[position]?.counts?.chunks.values.flatMap { $0 }.contains { $0.id == "minecraft:gold_ore" } == false)
        }
        h.close(); await h.finish()
    }

    @Test func lastWindowDemandCancelsAndDiscardsItsLateRead() async throws {
        let gate = AsyncReadGate<RegionBlockCounts>()
        let numbers = ReadNumbers()
        let h = try BlockCountHarness(chunks: [BlockSearchFixture.chunk(x: 0, count: 5)],
            read: { _, _, _ in await gate.read(String(await numbers.next())) })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let near = try h.point(8), far = try h.point(520)
        let first = SearchModel(queryStore: h.queries), second = SearchModel(queryStore: h.queries)
        first.captureBlockOrigin { BlockSearchAnchor(point: near, playerID: nil) }
        second.captureBlockOrigin { BlockSearchAnchor(point: far, playerID: nil) }
        first.text = "block: diamond"; second.text = "block: diamond"
        await gate.waitForRequest("0")
        let saved = try h.dimension.countBlocks(region: .init(x: 0, z: 0), matching: h.counts.catalog.blockIDs)
        first.cancel(); await first.waitForTasks()
        #expect(second.isSearchingFarther(for: second.text))
        second.cancel(); await second.waitForTasks()
        await gate.waitForCancellation("0")
        await gate.finish("0", with: saved)
        await h.counts.waitUntilFinished()
        #expect(!h.counts.isReading)
        #expect(h.counts.snapshot.dimensions[h.dimension.id]?.regions[.init(x: 0, z: 0)]?.counts == nil)
        let later = SearchModel(queryStore: h.queries)
        later.captureBlockOrigin { BlockSearchAnchor(point: near, playerID: nil) }
        later.text = "block: diamond"
        await gate.waitForRequest("1")
        await gate.finish("1", with: saved)
        await later.waitForSearch()
        #expect(h.counts.snapshot.dimensions[h.dimension.id]?.regions[saved.region]?.counts == saved)
        later.cancel(); h.close(); await h.finish()
    }

    @Test func replacedWorldCannotPublishAnOldReadAfterItsReplacementCompletes() async throws {
        let gate = AsyncReadGate<RegionBlockCounts>()
        let numbers = ReadNumbers()
        let h = try BlockCountHarness(chunks: [BlockSearchFixture.chunk(x: 0, count: 5)],
            read: { _, _, _ in await gate.read(String(await numbers.next())) })
        let nextRoot = try TestWorld.make(chunks: [BlockSearchFixture.chunk(x: 0, count: 19)])
        defer { h.close(); try? FileManager.default.removeItem(at: h.root); try? FileManager.default.removeItem(at: nextRoot) }
        let old = try h.dimension.countBlocks(region: .init(x: 0, z: 0), matching: h.counts.catalog.blockIDs)
        h.counts.setDemand([try h.point(8)])
        await gate.waitForRequest("0")
        let world = try World(contentsOf: nextRoot), source = WorldReadSource(world)
        let dimension = try #require(world.dimension("overworld"))
        h.counts.replace(world: source, dimensions: [dimension], cachePreparation: nil)
        await gate.waitForCancellation("0")
        await gate.waitForRequest("1")
        let newer = try dimension.countBlocks(region: old.region, matching: h.counts.catalog.blockIDs)
        await gate.finish("1", with: newer)
        await h.counts.waitForCounts()
        await gate.finish("0", with: old)
        await h.counts.waitUntilFinished()
        #expect(h.counts.snapshot.world === source)
        #expect(h.counts.snapshot.dimensions[dimension.id]?.regions[old.region]?.counts == newer)
        h.close(); await h.finish()
    }

    @Test func terrainChangeDuringReadIsFailedAndOnlyAChangedStampRetries() async throws {
        let entered = AsyncReadGate<Void>(), numbers = ReadNumbers()
        let h = try BlockCountHarness(chunks: [BlockSearchFixture.chunk(x: 0, count: 5)],
            read: { dimension, region, ids in
                let saved = try await WorldBlockCountStore.count(dimension, region: region, blockIDs: ids)
                if await numbers.next() == 0 { await entered.read("old") }
                return saved
            })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let region = RegionPosition(x: 0, z: 0)
        h.counts.setDemand([try h.point(8)])
        await entered.waitForRequest("old")
        try Data(TestWorld.regionFile([BlockSearchFixture.chunk(x: 0, count: 17)]))
            .write(to: h.dimension.regionURL(.terrain, at: region), options: .atomic)
        await entered.finish("old", with: ())
        await h.counts.waitForCounts()
        #expect(h.counts.snapshot.dimensions[h.dimension.id]?.coverage(of: region, matching: h.counts.catalog.blockIDs) == .failed)
        #expect(h.counts.snapshot.dimensions[h.dimension.id]?.regions[region]?.counts == nil)
        h.index.rebuild(firstDimension: h.dimension.id)
        await h.index.waitForIndex(); await h.counts.waitForCounts()
        let result = try #require(h.counts.snapshot.dimensions[h.dimension.id])
        #expect(result.coverage(of: region, matching: h.counts.catalog.blockIDs) == .complete)
        #expect(result.regions[region]?.counts?.chunks[.init(x: 0, z: 0)]?.first?.count == 17)
        h.close(); await h.finish()
    }
}
