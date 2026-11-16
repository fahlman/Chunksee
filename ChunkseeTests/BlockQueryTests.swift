import ChunkseeIndex
import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct BlockQueryTests {
    @Test func nearestRowsKeepFullTotalsInTypedAndSavedSearches() async throws {
        let h = try BlockCountHarness(chunks: (0..<220).map { BlockSearchFixture.chunk(x: $0, count: $0 + 1) })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let query = "block:diamond", west = try h.point(8), east = try h.point(219 * 16 + 8)
        let first = SearchModel(queryStore: h.queries), second = SearchModel(queryStore: h.queries)
        first.captureBlockOrigin { BlockSearchAnchor(point: west, playerID: nil) }
        second.captureBlockOrigin { BlockSearchAnchor(point: east, playerID: nil) }
        first.text = query; second.text = query
        await first.waitForSearch(); await second.waitForSearch()
        let windows: [(SearchModel, CGFloat)] = [(first, 8), (second, 3512)]
        for (model, expectedX) in windows {
            let listed = model.listedHits(for: query) { $0 == h.dimension.id }
            #expect(listed.total == 220 && listed.rows.count == 200)
            #expect(listed.rows.first?.position?.x == expectedX)
            #expect(CountedText.label("Search Results", count: listed.total, shown: listed.rows.count,
                                     locale: Locale(identifier: "en_US")) == "Search Results (first 200 of 220)")
            #expect(model.pinnedHits { $0 == h.dimension.id }.map(\.id) == listed.rows.map(\.id))
            let elsewhere = model.listedHits(for: query) { $0 == "minecraft:the_nether" }
            #expect(elsewhere.total == 0 && elsewhere.rows.isEmpty)
        }
        first.saveSearch()
        first.text = ""; second.text = ""
        await first.waitForSearch(); await second.waitForSearch()
        for (model, expectedX) in windows {
            let saved = model.listedHits(for: query) { $0 == h.dimension.id }
            #expect(saved.total == 220 && saved.rows.count == 200)
            #expect(saved.rows.first?.position?.x == expectedX)
            #expect(model.pinnedHits { $0 == h.dimension.id }.map(\.id) == saved.rows.map(\.id))
        }
        first.cancel(); second.cancel(); h.close(); await h.finish()
        #expect(first.listedHits(for: query) { _ in true }.total == 0)
    }

    @Test func windowsShareCountsButSavedAndTypedSearchesKeepTheirOwnOrigins() async throws {
        let log = BlockReadLog()
        let h = try BlockCountHarness(chunks: [0, 32].map { BlockSearchFixture.chunk(x: $0, count: 3) },
            read: { dimension, region, ids in
                await log.record(region, ids)
                return try await WorldBlockCountStore.count(dimension, region: region, blockIDs: ids)
            })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let saved = "block: diamond"
        h.saved.add(saved)
        let first = SearchModel(queryStore: h.queries), second = SearchModel(queryStore: h.queries)
        var center = try h.point(8)
        let far = try h.point(520)
        first.captureBlockOrigin { BlockSearchAnchor(point: center, playerID: nil) }
        second.captureBlockOrigin { BlockSearchAnchor(point: far, playerID: nil) }
        first.text = saved; second.text = saved
        await first.waitForSearch(); await second.waitForSearch()
        #expect(first.results.first?.position == CGPoint(x: 8, y: 8))
        #expect(second.results.first?.position == CGPoint(x: 520, y: 8))
        #expect(first.results(for: saved).first?.position != second.results(for: saved).first?.position)
        #expect(await log.calls.count == 2)

        center = far // A new viewport/selection is not a new search.
        h.index.rebuild(firstDimension: h.dimension.id)
        await h.index.waitForIndex(); await first.waitForSearch()
        #expect(first.results.first?.position == CGPoint(x: 8, y: 8))
        first.text = "block:diamond"
        await first.waitForSearch()
        #expect(first.results.first?.position == CGPoint(x: 520, y: 8))
        #expect(first.results(for: saved).first?.position == CGPoint(x: 8, y: 8))
        #expect(await log.calls.count == 2)
        first.cancel(); await first.waitForTasks()
        #expect(second.results.first?.position == CGPoint(x: 520, y: 8))
        second.cancel(); await second.waitForTasks()
        h.close(); await h.finish()
    }

    @Test func playerOriginFollowsTheCapturedIdentityAndKeepsLastPointWhenAbsent() async throws {
        let h = try BlockCountHarness(chunks: [0, 32, 64].map { BlockSearchFixture.chunk(x: $0, count: 3) })
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let id = UUID(), otherID = UUID()
        func player(_ id: UUID, x: Double, dimension: String = "minecraft:overworld") -> PlayerInfo {
            PlayerInfo(uuid: id, nbt: .compound(["Dimension": .string(dimension),
                "Pos": .list([.double(x), .double(64), .double(8)])]))
        }
        h.players.publish([player(id, x: 8), player(otherID, x: 520)])
        let model = SearchModel(queryStore: h.queries)
        var selected = BlockSearchAnchor(point: try h.point(8), playerID: id)
        model.captureBlockOrigin { selected }
        model.text = "block: diamond"
        await model.waitForSearch()
        #expect(model.results.first?.position?.x == 8)
        selected = BlockSearchAnchor(point: try h.point(520), playerID: otherID)
        h.players.publish([player(id, x: 1032), player(otherID, x: 8)])
        await model.waitForSearch()
        #expect(model.results.first?.position?.x == 1032)
        h.players.publish([player(id, x: 8, dimension: "minecraft:the_nether"), player(otherID, x: 520)])
        await model.waitForSearch()
        #expect(model.results.first?.position?.x == 1032)
        h.players.publish([])
        await model.waitForSearch()
        #expect(model.results.first?.position?.x == 1032)
        model.cancel(); h.close(); await h.finish()
    }

    @Test func panningAndSelectingARealSearchHitRetainTheSessionOrigin() async throws {
        let root = try TestWorld.make(chunks: [0, 32].map { BlockSearchFixture.chunk(x: $0, count: 3) })
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(root, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        defer { session.close() }
        let map = try #require(session.map)
        map.viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 1)
        session.search.text = "block: diamond"
        await session.search.waitForSearch()
        let initial = session.search.results.map(\.id)
        let farther = try #require(session.search.results.last)
        session.selection.choose(.hit(query: session.search.text, id: farther.id))
        map.viewport = MapViewport(center: CGPoint(x: 520, y: 8), scale: 8)
        session.search.rebuild(firstDimension: session.selectedDimensionID)
        await session.search.waitForIndex(); await session.search.waitForSearch()
        #expect(session.search.results.map(\.id) == initial)
        #expect(session.search.results.first?.position?.x == 8)
        session.close(); await session.resources.waitUntilClosed()
    }

    @Test func regroupingDiscardsOldLabelsAndMissingOreDefinitionsAreExplicit() async throws {
        let h = try BlockCountHarness(chunks: [BlockSearchFixture.chunk(x: 0, count: 3)])
        defer { h.close(); try? FileManager.default.removeItem(at: h.root) }
        let model = SearchModel(queryStore: h.queries), point = try h.point(8)
        model.captureBlockOrigin { BlockSearchAnchor(point: point, playerID: nil) }
        model.text = "block: diamond"
        await model.waitForSearch()
        #expect(model.results.first?.title(in: .unavailable) == "Diamond Ores")
        h.counts.setCatalog(try h.catalog(ores: ["minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"]))
        // Catalog publication immediately retires the old grouped result, before reranking.
        #expect(model.results.isEmpty)
        await model.waitForSearch()
        #expect(model.results.first?.title(in: .unavailable) == "Diamond Ore")
        h.counts.setCatalog(NotableBlock.Catalog(tags: [:]))
        #expect(!model.hasOreDefinitions(for: model.text))
        #expect(model.hasOreDefinitions(for: "item:diamond"))
        await model.waitForSearch()
        #expect(model.results.isEmpty)
        model.cancel(); h.close(); await h.finish()
    }
}
