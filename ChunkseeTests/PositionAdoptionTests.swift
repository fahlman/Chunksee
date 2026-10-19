import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PositionAdoptionTests {
    @Test func existingBiomeCacheKeysDecodeAsKitPositions() throws {
        // The old ChunkCoordinate synthesized Codable used this exact x/z shape.
        let data = Data(#"[{"x":-33,"z":-1},"minecraft:plains"]"#.utf8)
        let decoded = try JSONDecoder().decode([ChunkPosition: String].self, from: data)
        #expect(decoded == [ChunkPosition(x: -33, z: -1): "minecraft:plains"])
    }

    @Test func negativeChunkOriginsReachTheSameTerrainAndBiome() async throws {
        let spec = TestWorld.chunk(x: -33, z: -1, palette: ["minecraft:gold_block"]) { _, _, _ in 0 }
        let url = try TestWorld.make(chunks: [spec])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let chunk = ChunkPosition(x: -33, z: -1)
        let map = MapModel(dimension: dimension, center: CGPoint(x: -527.5, y: -15.5))
        map.loadTopBlocks(at: map.viewport.center)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: map.viewport.center)?.id == "minecraft:gold_block")
        #expect(map.topBlocks.keys.contains(chunk))
        let facts = await RegionData.read(dimension, region: chunk.region)
        #expect(facts.biomes[chunk] == "minecraft:plains")
        map.close()
        await map.waitForRenders()
    }

    @Test func biomeAreasOmitUnrepresentableChunkOrigins() {
        let areas = BiomeScanner.areas(from: [ChunkPosition(x: .max, z: 0): "minecraft:plains",
                                            ChunkPosition(x: .min, z: 0): "minecraft:plains",
                                            ChunkPosition(x: -1, z: -1): "minecraft:plains"])
        #expect(areas.count == 1)
        #expect(areas.first?.chunkCount == 1)
        #expect(areas.first?.position == CGPoint(x: -8, y: -8))
    }
}
