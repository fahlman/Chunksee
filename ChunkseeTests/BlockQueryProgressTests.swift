import ChunkseeIndex
import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct BlockQueryProgressTests {
    /// Hold nonempty queries independently of count reads, so intermediate publications and
    /// replacement cancellation are observable without timing a large world.
    private actor Queries {
        let gate = AsyncReadGate<Void>()
        private var isGated = true
        private(set) var requests: [SearchRequest] = []
        var loadedRegions: [Int] { requests.map(Self.loadedRegions) }

        private nonisolated static func loadedRegions(_ request: SearchRequest) -> Int {
            guard let blocks = request.blocks,
                  let counts = blocks.counts.dimensions[blocks.point.dimension] else { return 0 }
            return counts.regions.values.filter { $0.counts != nil }.count
        }

        func execute(_ request: SearchRequest) async -> WorldQueryStore.Results {
            if Self.loadedRegions(request) > 0 {
                let key = String(requests.count)
                requests.append(request)
                if isGated { await gate.read(key) }
            }
            return await WorldSearch.execute(request)
        }

        func allowFutureReads() { isGated = false }
    }

    @MainActor private final class Search {
        let countGate: AsyncReadGate<Void>
        let queries: Queries
        let h: BlockCountHarness
        let model: SearchModel
        let point: BlockSearchPoint
        let playerID: UUID
        let query = "block:diamond"

        init(saved: Bool) throws {
            let countGate = AsyncReadGate<Void>(), queries = Queries(), playerID = UUID()
            self.countGate = countGate; self.queries = queries; self.playerID = playerID
            let h = try BlockCountHarness(chunks: [0, 32, 64, 96].map { BlockSearchFixture.chunk(x: $0, count: 3) },
                read: { dimension, region, ids in
                    await countGate.read(String(region.x))
                    return try await WorldBlockCountStore.count(dimension, region: region, blockIDs: ids)
                }, execute: { await queries.execute($0) })
            self.h = h
            let point = try h.point(8)
            self.point = point
            h.players.publish([Self.player(playerID, x: 8)])
            let model = SearchModel(queryStore: h.queries)
            self.model = model
            let anchor = BlockSearchAnchor(point: point, playerID: playerID)
            model.captureBlockOrigin { anchor }
            if saved { h.saved.add(query) } else { model.text = query }
        }

        static func player(_ id: UUID, x: Double) -> PlayerInfo {
            PlayerInfo(uuid: id, nbt: .compound(["Dimension": .string("minecraft:overworld"),
                "Pos": .list([.double(x), .double(64), .double(8)])]))
        }

        func enterFirstQuery() async {
            await countGate.waitForRequest("0")
            await countGate.finish("0", with: ())
            await countGate.waitForRequest("1")
            await queries.gate.waitForRequest("0")
        }

        func expected(_ query: String, point: BlockSearchPoint) async -> SearchMatches {
            let request = SearchRequest(queries: [query], index: model.index, players: model.players,
                playerNames: [:], gameNames: .unavailable,
                blocks: BlockQueryInput(counts: h.counts.snapshot, catalog: h.counts.catalog, point: point))
            return await WorldSearch.execute(request)[query] ?? .all([])
        }

        func finish() async {
            model.cancel(); h.close()
            await countGate.releaseAllAndFuture(with: ())
            await queries.gate.releaseAllAndFuture(with: ())
            await h.finish()
            try? FileManager.default.removeItem(at: h.root)
        }
    }

    @Test(arguments: [false, true]) func progressFinishesOnePassThenUsesTheLatestCounts(saved: Bool) async throws {
        let s = try Search(saved: saved)
        await s.enterFirstQuery()
        await s.countGate.finish("1", with: ())
        await s.countGate.waitForRequest("2")
        await s.countGate.finish("2", with: ())
        await s.countGate.waitForRequest("3")
        #expect(await s.queries.loadedRegions == [1])

        await s.queries.gate.finish("0", with: ())
        await s.queries.gate.waitForRequest("1")
        #expect(s.model.listedHits(for: s.query) { _ in true }.total == 1)
        #expect(s.model.isSearchingFarther(for: s.query))
        #expect(await s.queries.loadedRegions == [1, 3])

        await s.countGate.finish("3", with: ())
        await s.h.counts.waitForCounts()
        await s.queries.gate.finish("1", with: ())
        await s.queries.gate.waitForRequest("2")
        #expect(s.model.listedHits(for: s.query) { _ in true }.total == 3)
        #expect(await s.queries.loadedRegions == [1, 3, 4])
        await s.queries.gate.finish("2", with: ())
        await s.model.waitForSearch()

        let expected = await s.expected(s.query, point: s.point)
        let final = s.model.listedHits(for: s.query) { _ in true }
        #expect(final.total == 4)
        #expect(final.rows.map(\.id) == expected.hits.map(\.id))
        #expect(!s.model.isSearching)
        #expect(await s.queries.loadedRegions == [1, 3, 4])
        await s.finish()
    }

    enum Replacement: CaseIterable { case query, catalog, player }

    @Test(arguments: Replacement.allCases) func changedMeaningCancelsWithoutWaitingForOldResults(_ replacement: Replacement) async throws {
        let s = try Search(saved: false)
        do {
            let regrouped = try s.h.catalog(ores: ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"])
            let moved = try s.h.point(1032)
            await s.enterFirstQuery()
            await s.countGate.finish("1", with: ())
            await s.countGate.waitForRequest("2")
            switch replacement {
            case .query: s.model.text = "block:emerald"
            case .catalog: s.h.counts.setCatalog(regrouped)
            case .player: s.h.players.publish([Search.player(s.playerID, x: moved.origin.x)])
            }
            await s.queries.gate.waitForCancellation("0")
            // The replacement starts while the cancelled read is deliberately still held.
            await s.queries.gate.waitForRequest("1")
            #expect(await s.queries.loadedRegions == [1, 2])
            await s.queries.allowFutureReads()
            await s.queries.gate.finish("1", with: ())
            await s.countGate.releaseAllAndFuture(with: ())
            await s.model.waitForSearch()

            let expected = await s.expected(s.model.text, point: replacement == .player ? moved : s.point)
            let current = s.model.matches(for: s.model.text)
            #expect(current.hits.map(\.id) == expected.hits.map(\.id))
            #expect(current.hits.map { $0.title(in: .unavailable) } == expected.hits.map { $0.title(in: .unavailable) })
            await s.queries.gate.finish("0", with: ())
            await s.model.waitForTasks()
            #expect(s.model.matches(for: s.model.text).hits.map(\.id) == current.hits.map(\.id))
        } catch {
            await s.finish()
            throw error
        }
        await s.finish()
    }

    @Test(arguments: [false, true]) func closingDiscardsThePendingSnapshotAndLateResults(saved: Bool) async throws {
        let s = try Search(saved: saved)
        await s.enterFirstQuery()
        await s.countGate.finish("1", with: ())
        await s.countGate.waitForRequest("2")
        s.model.cancel()
        await s.queries.gate.waitForCancellation("0")
        await s.finish()
        #expect(await s.queries.loadedRegions == [1])
        #expect(s.model.matches(for: s.query).hits.isEmpty)
        #expect(!s.model.isSearching)
    }
}
