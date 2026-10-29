import ChunkseeKit
import ChunkseeKitTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct BiomeBlendingTests {
    @Test func averagesTheFullSquareInIntegerRGBAtTheSameHeight() {
        let center = BlockPosition(blockX: -16, blockY: -40, blockZ: -1)
        var visited: Set<BlockPosition> = []
        let color = BiomeBlending.color(at: center) { point in
            visited.insert(point)
            return point.x < center.x ? 0xff0000 : 0x0000ff
        }
        #expect(color == 0x660099) // Ten red samples and fifteen blue samples.
        #expect(visited.count == 25 && Set(visited.map(\.y)) == [-40])
        #expect(Set(visited.map(\.x)) == Set(-18 ... -14))
        #expect(Set(visited.map(\.z)) == Set(-3 ... 1))
        #expect(BiomeBlending.color(at: center) { $0 == center ? 0xffffff : 0 } == 0x0a0a0a)
        #expect(BiomeBlending.color(at: center) { $0 == center ? 0x010203 : 0 } == 0)
        #expect(BiomeBlending.color(at: center) { _ in 0xffffff } == 0xffffff)
        #expect(BiomeBlending.color(at: center) { $0 == center ? nil : 0xffffff } == nil)
    }

    @Test func invalidNeighborhoodsNeverWrapOrRequestOutOfRangeCoordinates() {
        for (x, z) in [(Int.min, 0), (Int.max, 0), (0, Int.min), (0, Int.max),
                       (Int(Int32.min), 0), (Int(Int32.max), 0), (0, Int(Int32.min) + 1), (0, Int(Int32.max) - 1)] {
            var requested = 0
            let color = BiomeBlending.color(at: .init(blockX: x, blockY: Int.max, blockZ: z)) { _ in
                requested += 1
                return 0xffffff
            }
            #expect(color == nil && requested == 0)
        }
        for y in [Int.min, Int.max] {
            let color = BiomeBlending.color(at: .init(blockX: Int(Int32.min) + 2, blockY: y, blockZ: Int(Int32.max) - 2)) {
                #expect($0.y == y)
                return 0x123456
            }
            #expect(color == 0x123456)
        }
    }

    @Test func denseSamplesMatchTheSquareOracleForEverySourceAcrossHeightsAndEdges() {
        var samples = BiomeColorSamples(originX: -16, originZ: -32, blendsColors: true)
        let heights = [Int.min, -40, Int.max]
        func color(_ point: BlockPosition, _ source: BiomeColor) -> UInt32? {
            if source == .dryFoliage, point.x == -2, point.z == -17 { return nil }
            let sourceIndex = UInt32(BiomeColor.allCases.firstIndex(of: source)!)
            return ((UInt32(truncatingIfNeeded: point.x) & 255) << 16)
                | ((UInt32(truncatingIfNeeded: point.z) & 255) << 8)
                | ((UInt32(truncatingIfNeeded: point.y) & 63) + sourceIndex * 64)
        }
        for y in heights {
            for z in -32 ..< -16 {
                for x in -16 ..< 0 {
                    for source in BiomeColor.allCases {
                        samples.request(source, at: .init(blockX: x, blockY: y, blockZ: z))
                    }
                }
            }
        }
        var calls: [BiomeColor: Set<BlockPosition>] = [:]
        var duplicates = 0
        samples.resolveColors { _, point, source in
            if !calls[source, default: []].insert(point).inserted { duplicates += 1 }
            return color(point, source)
        }
        #expect(duplicates == 0)
        #expect(calls.values.allSatisfy { $0.count == 20 * 20 * heights.count })
        for y in heights {
            for z in [-32, -24, -17] {
                for x in [-16, -8, -1] {
                    let point = BlockPosition(blockX: x, blockY: y, blockZ: z)
                    for source in BiomeColor.allCases {
                        let expected = BiomeBlending.color(at: point) { color($0, source) }
                        #expect(samples.color(source, at: point) == expected)
                    }
                }
            }
        }
        #expect(samples.index(at: .init(blockX: -16, blockY: 0, blockZ: -32)) == nil)
        #expect(samples.index(at: .init(blockX: Int.max, blockY: -40, blockZ: Int.min)) == nil)
    }

    @Test func sparseRequestsKeepTheirSourceAndUnblendedCentersWithoutInventingMissingColors() {
        let first = BlockPosition(blockX: -16, blockY: 3, blockZ: -32)
        let second = BlockPosition(blockX: -15, blockY: 3, blockZ: -32)
        var samples = BiomeColorSamples(originX: -16, originZ: -32, blendsColors: true)
        samples.request(.grass, at: first)
        samples.request(.grass, at: first)
        samples.request(.water, at: second)
        var calls: [BiomeColor: Int] = [:]
        samples.resolveColors { _, _, source in
            calls[source, default: 0] += 1
            return source == .grass ? 0x123456 : 0xabcdef
        }
        #expect(calls == [.grass: 25, .water: 25])
        #expect(samples.color(.grass, at: first) == 0x123456)
        #expect(samples.color(.water, at: second) == 0xabcdef)
        #expect(samples.color(.grass, at: second) == nil)
        #expect(samples.color(.foliage, at: first) == nil)
        var unblended = BiomeColorSamples(originX: -16, originZ: -32, blendsColors: false)
        unblended.request(.grass, at: first)
        unblended.request(.water, at: first)
        var resolved = false
        unblended.resolveColors { _, _, _ in resolved = true; return 0 }
        #expect(unblended.points == [first] && !resolved)
        #expect(unblended.index(at: first) == 0)
        #expect(unblended.color(.grass, at: first) == nil)
    }

    @Test func denseSamplesKeepAnUnblendableCenterAtTheWorldCoordinateLimit() {
        let origin = Int(Int32.min)
        let point = BlockPosition(blockX: origin, blockY: Int.max, blockZ: 0)
        var samples = BiomeColorSamples(originX: origin, originZ: 0, blendsColors: true)
        samples.request(.grass, at: point)
        var resolved = false
        samples.resolveColors { _, _, _ in resolved = true; return 0xffffff }
        #expect(samples.points == [point] && !resolved)
        #expect(samples.index(at: point) == 0)
        #expect(samples.color(.grass, at: point) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aToggleRejectsOldTilesWithoutCancellingHoverOrCoordinateCopies() async throws {
        let url = try TestWorld.make(chunks: [.init(x: 0, z: 0, nbt: Fixtures.chunk(x: 0, z: 0,
            dataVersion: SaveVersion.java26_3, sections: [Fixtures.section(y: 0, palette: [.string("minecraft:stone")])]))])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        let render = AsyncReadGate<RegionTileRenderer.RenderedTile?>(), columns = AsyncReadGate<MapModel.TopBlockRead?>()
        let map = MapModel(savedLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: CGPoint(x: 8, y: 8),
            renderTile: { renderer, _ in await render.read(String(renderer.blendsBiomeColors)) },
            readTopBlocks: { chunk, _, _ in await columns.read(String(chunk.x)) })
        map.requestTiles(visibleIn: CGSize(width: 16, height: 16))
        map.loadTopBlocks(at: CGPoint(x: 1, y: 1))
        var copiedY: Int?
        map.readTopBlock(at: CGPoint(x: 17, y: 1)) { copiedY = $0?.y }
        await render.waitForRequest("false")
        let previousRenderer = map.currentRenderer
        await columns.waitForRequest("0")
        await columns.waitForRequest("1")
        map.setBiomeBlending(true)
        await render.waitForCancellation("false")
        await render.waitForRequest("true")
        map.setBiomeBlending(true)
        let blended = try #require(CGImage.rgba([10, 20, 30, 255], width: 1, height: 1))
        await render.finish("true", with: try map.currentRenderer.fixtureTile(blended, for: .init(x: 0, z: 0)))
        await map.waitUntilIdle()
        let old = try #require(CGImage.rgba([40, 50, 60, 255], width: 1, height: 1))
        await render.finish("false", with: try previousRenderer.fixtureTile(old, for: .init(x: 0, z: 0)))
        let block = RegionTileRenderer.TopBlock(id: "minecraft:stone", y: 15, waterDepth: 0)
        await columns.finish("0", with: (file, Array(repeating: block, count: 256)))
        await columns.finish("1", with: (file, Array(repeating: block, count: 256)))
        await map.waitForRenders()
        #expect(map.tiles[.init(x: 0, z: 0)]?.image === blended && map.currentRenderer.blendsBiomeColors)
        #expect(map.topBlock(at: CGPoint(x: 1, y: 1)) == block && copiedY == 15)
        #expect(await render.requested == ["false", "true"])
        map.close()
        map.setBiomeBlending(false)
        #expect(map.blendsBiomeColors)
    }

    @Test func documentSettingsAndRereadsKeepEachDimensionsChoice() async throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("DIM-1/region"), withIntermediateDirectories: true)
        let defaults = TestDefaults.make()
        let resources = try await WorldResources(snapshot: try await WorldSnapshot.read(url), names: PlayerNames(defaults: defaults),
            savedSearches: SavedSearches(defaults: defaults), defaults: defaults, cacheRoot: nil, watchWorld: { _, _ in nil })
        let first = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        let second = WorldSession(resources: resources, dimensionID: "minecraft:the_nether")
        #expect(first.map?.blendsBiomeColors == false && second.map?.blendsBiomeColors == false)
        first.map?.setBiomeBlending(true)
        first.saveView()
        second.saveView()
        let restored = WorldSession(resources: resources, dimensionID: "minecraft:overworld")
        #expect(restored.map?.blendsBiomeColors == true && second.map?.blendsBiomeColors == false)
        first.map?.setBiomeBlending(false)
        restored.restoreView(from: first)
        #expect(restored.map?.blendsBiomeColors == false)
        let saved = WorldSettings(id: resources.settings.worldID, defaults: defaults)
        saved.save(MapViewport(), for: "minecraft:overworld", selected: nil)
        #expect(saved.blendsBiomeColors(for: "minecraft:overworld")) // Other saves preserve the choice.
        resources.close()
        await resources.waitUntilClosed()
    }
}
