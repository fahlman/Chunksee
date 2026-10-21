import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSurfaceTests {
    @Test func motionBlockingHeightDoesNotHideTheVisibleSurface() async throws {
        // Flowers at Y 1 are visible, but do not raise MOTION_BLOCKING above the stone at Y 0.
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:poppy"]) { _, y, _ in
            y == 0 ? 1 : y == 1 ? 2 : 0
        }
        guard case .compound(var root) = spec.nbt else {
            Issue.record("Expected a compound chunk fixture")
            return
        }
        root["Heightmaps"] = .compound([
            "MOTION_BLOCKING": .longArray(Fixtures.pack(Array(repeating: 1, count: 256), bits: 9))
        ])
        spec.nbt = .compound(root)
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))

        let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(columns.allSatisfy { $0?.y == 1 && $0?.color == BlockColors.color(for: "minecraft:poppy") })
        #expect(blocks.allSatisfy { $0 == .init(id: "minecraft:poppy", y: 1, waterDepth: 0) })

        let pixels = try #require(try await RegionTileRenderer(dimension: dimension).pixels(for: .init(x: 0, z: 0)))
        let flower = try #require(BlockColors.color(for: "minecraft:poppy"))
        let offset = (5 * RegionTileRenderer.side + 5) * 4
        #expect(Array(pixels[offset ..< offset + 4]) == [flower.red, flower.green, flower.blue, 255])
    }

    @Test func anUnreadableSurfaceDoesNotExposeLowerBlocks() throws {
        // A damaged reference at the top cannot establish air; the stone beneath is not a known surface.
        let spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone"]) { x, y, _ in
            if x == 0, y == 15 { return 7 }
            return y == 0 ? 1 : 0
        }
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))

        let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0))
        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(columns[0] == nil && blocks[0] == nil)
        #expect(blocks[1] == .init(id: "minecraft:stone", y: 0, waterDepth: 0))
    }
}
