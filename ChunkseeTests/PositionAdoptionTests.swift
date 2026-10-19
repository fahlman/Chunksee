import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PositionAdoptionTests {
    @Test func continuousGeometryMatchesKitsRegionSize() throws {
        let xStep = try #require(RegionPosition(x: 1, z: 0).blockOrigin)
        let zStep = try #require(RegionPosition(x: 0, z: 1).blockOrigin)
        #expect(MapViewport.regionSideInBlocks == CGFloat(xStep.x))
        #expect(MapViewport.regionSideInBlocks == CGFloat(zStep.z))
    }

    @Test func unrepresentableRegionsCannotDrawOrDistortFitWorld() {
        let size = CGSize(width: 800, height: 600)
        let invalid = RegionPosition(x: .max, z: .min)
        let valid = RegionPosition(x: -2, z: 3)
        #expect(MapViewport().viewRect(for: invalid, in: size) == nil)
        #expect(MapViewport.fitting([invalid], in: size) == nil)
        #expect(MapViewport.fitting([valid, invalid], in: size) == MapViewport.fitting([valid], in: size))
        #expect(MapViewport().distanceToCenter(invalid) > MapViewport().distanceToCenter(valid))
    }

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
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: CGPoint(x: -527.5, y: -15.5))
        map.loadTopBlocks(at: map.viewport.center)
        await map.waitForTopBlocks()
        #expect(map.topBlock(at: map.viewport.center)?.id == "minecraft:gold_block")
        #expect(map.topBlocks.keys.contains(chunk))
        let facts = try await RegionReader.scan(dimension, region: chunk.region)
        #expect(facts.surfaceBiomes[chunk] == "minecraft:plains")
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
