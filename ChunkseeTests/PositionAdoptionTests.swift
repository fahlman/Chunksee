import ChunkseeIndex
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

    @Test func chunkBoundariesReachTheSameTerrainAndBiome() async throws {
        let examples: [(point: CGPoint, chunk: ChunkPosition, y: Int, id: String)] = [
            (CGPoint(x: -527.5, y: -15.5), .init(x: -33, z: -1), 0, "minecraft:gold_block"),
            (CGPoint(x: -512.1, y: -1.1), .init(x: -33, z: -1), 9, "minecraft:stone"),
            (CGPoint(x: -512, y: -1), .init(x: -32, z: -1), 13, "minecraft:stone"),
            (CGPoint(x: 0, y: -0.1), .init(x: 0, z: -1), 13, "minecraft:stone"),
            (CGPoint(x: 16, y: 16), .init(x: 1, z: 1), 0, "minecraft:gold_block"),
        ]
        let chunks = Set(examples.map(\.chunk)).map { chunk in
            TestWorld.chunk(x: chunk.x, z: chunk.z, palette: ["minecraft:air", "minecraft:gold_block", "minecraft:stone"]) { x, y, z in
                y <= (x + 3 * z) % 16 ? (z < 8 ? 1 : 2) : 0
            }
        }
        let url = try TestWorld.make(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        for example in examples {
            let map = MapModel(definitions: { .unknown }, gameResources: { .unavailable }, savedLighting: { nil }, nightLighting: { nil }, work: BackgroundWork(), dimension: dimension, center: example.point)
            // Copy Coordinates can read a column before the pointer has hovered over its chunk.
            var read: RegionTileRenderer.TopBlock?
            map.readTopBlock(at: example.point) { read = $0 }
            await map.waitForCoordinateReads()
            #expect(read?.id == example.id && read?.y == example.y)
            map.loadTopBlocks(at: example.point)
            await map.waitForTopBlocks()
            #expect(map.topBlock(at: example.point)?.id == example.id)
            #expect(map.topBlock(at: example.point)?.y == example.y)
            #expect(map.topBlocks.keys.contains(example.chunk))
            let facts = try await RegionReader.scan(dimension, region: example.chunk.region, options: RegionReader.options())
            var content = MapContent(gameNames: .unavailable)
            content.biomes = ChunkseeIndex.RegionIndex(facts, caveBiomeIDs: BiomePresentation.caveBiomeIDs, notableBlocks: .init(tags: [:])).biomes
            #expect(content.biome(at: example.point) == "minecraft:plains")
            map.close()
            await map.waitForRenders()
        }
    }

    @Test func biomeAreasOmitUnrepresentableChunkOrigins() {
        let areas = BiomePresentation.areas(from: [ChunkPosition(x: .max, z: 0): "minecraft:plains",
                                            ChunkPosition(x: .min, z: 0): "minecraft:plains",
                                            ChunkPosition(x: -1, z: -1): "minecraft:plains"])
        #expect(areas.count == 1)
        #expect(areas.first?.chunkCount == 1)
        #expect(areas.first?.position == CGPoint(x: -8, y: -8))
    }
}
