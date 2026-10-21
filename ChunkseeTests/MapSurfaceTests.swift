import Foundation
import ChunkseeKit
import ChunkseeKitTestSupport
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MapSurfaceTests {
    @Test func uniformWaterRunsKeepTheSameDepthInPixelsAndHover() async throws {
        let water = NBT.string("minecraft:water")
        let gapped = Fixtures.chunk(x: 0, z: 0, dataVersion: SaveVersion.java26_3, sections: [
            Fixtures.section(y: 0, palette: [water]),
            .compound(["Y": .int(1)]),
            Fixtures.section(y: 2, palette: [water]),
            Fixtures.section(y: 3, palette: [water]),
        ], extra: ["yPos": .int(0)])
        let url = try TestWorld.make(chunks: [.init(x: 0, z: 0, nbt: gapped)])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))
        for (height, expectedDepth) in [(53, 22), (63, 32), (40, 9), (15, 16)] {
            let columns = try #require(RegionTileRenderer.columns(in: file, localX: 0, localZ: 0, cutawayY: height))
            let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0, cutawayY: height))
            #expect(columns.allSatisfy { $0?.y == height && $0?.waterDepth == expectedDepth })
            #expect(blocks.allSatisfy { $0 == .init(id: "minecraft:water", y: height, waterDepth: expectedDepth) })
            let pixels = try #require(try await RegionTileRenderer(dimension: dimension, cutawayY: height)
                .pixels(for: .init(x: 0, z: 0)))
            let column = try #require(columns[0])
            let color = RegionTileRenderer.baseColor(for: column)
            #expect(Array(pixels[0..<4]) == [color.red, color.green, color.blue, 255])
        }
    }

    @Test func roofFallbackKeepsTheClippedStartAndSkipsMissingSections() throws {
        let stone = NBT.string("minecraft:netherrack")
        let short = try Chunk(nbt: Fixtures.chunk(x: 0, z: 0, sections: [
            Fixtures.section(y: 0, palette: [stone]),
        ], extra: ["yPos": .int(0)]))
        var shortColors = RegionTileRenderer.ColorSections(short)
        let clipped = shortColors.topColumns(from: .height(127), underCeiling: true)
        #expect(clipped.allSatisfy { $0?.y == 10 })

        // The requested start is below the highest stored section, but in a gap. Its five-block
        // roof band still starts at Y 30, so the next stored block at Y 15 is already below it.
        let gapped = try Chunk(nbt: Fixtures.chunk(x: 0, z: 0, sections: [
            Fixtures.section(y: 0, palette: [stone]),
            Fixtures.section(y: 3, palette: [stone]),
        ], extra: ["yPos": .int(0)]))
        var gappedColors = RegionTileRenderer.ColorSections(gapped)
        let belowGap = gappedColors.topColumns(from: .height(30), underCeiling: true)
        #expect(belowGap.allSatisfy { $0?.y == 15 })
        let dark = BlockColors.color(for: "minecraft:netherrack")?.shaded(0.6)
        #expect(clipped.allSatisfy { $0?.color == dark } && belowGap.allSatisfy { $0?.color == dark })
    }

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

    @Test func worldSurfaceRetainsEmptyColumnsWaterAndDisplayTransparency() throws {
        var spec = TestWorld.chunk(x: 0, z: 0, palette: ["minecraft:air", "minecraft:stone", "minecraft:light", "minecraft:water"]) { x, y, _ in
            if x == 0 { return 0 }
            if y == 0 { return 1 }
            if x == 1, y == 4 { return 2 }
            if x == 2, y <= 4 { return 3 }
            return 0
        }
        guard case .compound(var root) = spec.nbt else {
            Issue.record("Expected a compound chunk fixture")
            return
        }
        let heights = (0..<256).map { i in i % 16 == 0 ? 0 : i % 16 <= 2 ? 5 : 1 }
        root["Heightmaps"] = .compound(["WORLD_SURFACE": .longArray(Fixtures.pack(heights, bits: 9))])
        spec.nbt = .compound(root)
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(try World(contentsOf: url).dimension("overworld"))
        let file = try #require(try dimension.region(x: 0, z: 0))

        let blocks = try #require(RegionTileRenderer.topBlocks(in: file, localX: 0, localZ: 0))
        #expect(blocks[0] == nil)
        #expect(blocks[1] == .init(id: "minecraft:stone", y: 0, waterDepth: 0))
        #expect(blocks[2] == .init(id: "minecraft:water", y: 4, waterDepth: 4))
        #expect(blocks[3] == .init(id: "minecraft:stone", y: 0, waterDepth: 0))
    }
}
