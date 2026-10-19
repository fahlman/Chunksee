import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SlimeChunkTests {
    @Test(arguments: [RegionPosition(x: 0, z: 0), .init(x: -2, z: -1), .init(x: 3, z: -4)])
    func masksMatchThePublishedRuleAtEveryChunk(_ region: RegionPosition) throws {
        let seed: Int64 = -4399779792530681128
        let image = try #require(SlimeChunks.image(region: region, seed: seed))
        #expect(image.width == 32 && image.height == 32)
        let data = try #require(image.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        for z in 0..<32 { for x in 0..<32 {
            let expected = World.isSlimeChunk(x: Int32(region.x * 32 + x), z: Int32(region.z * 32 + z), seed: seed)
            #expect((pixels[(z * 32 + x) * 4 + 3] > 0) == expected)
        } }
        #expect(SlimeChunks.image(region: .init(x: Int.max, z: Int.min), seed: seed) == nil)
    }

    @Test func negativeFractionalReadoutsUseTheContainingChunk() {
        let point = CGPoint(x: -0.1, y: -16.1), seed: Int64 = 42
        let expected = World.isSlimeChunk(x: -1, z: -2, seed: seed) ? "Slime chunk" : "Not a slime chunk"
        #expect(SlimeChunks.description(at: point, seed: seed) == expected)
        #expect(SlimeChunks.description(at: CGPoint(x: CGFloat.nan, y: 0), seed: seed) == nil)
    }

    @Test func imagesAreReusedNewRegionsAreAddedAndVisibilityIsRememberedPerDimension() async throws {
        let defaults = TestDefaults.make(), world = URL(fileURLWithPath: "/tmp/Slime Overlay Fixture")
        let visibility = LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults)
        let region = RegionPosition(x: 0, z: 0), added = RegionPosition(x: -1, z: 0)
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: 42, regions: [region])
        layer.restoreVisibility(from: visibility)
        #expect(!layer.isShown && layer.visibleImages.isEmpty)
        layer.isShown = true
        await layer.waitForImages()
        let image = try #require(layer.visibleImages[region])
        layer.regionsChanged([region, added])
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === image)
        #expect(layer.visibleImages[added] != nil)
        layer.isShown = false
        #expect(layer.visibleImages.isEmpty)
        layer.isShown = true
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === image)
        let restored = LayerVisibility(world: world, dimension: "minecraft:overworld", defaults: defaults)
        #expect(restored.rememberedSlimeChunks)
        let nether = LayerVisibility(world: world, dimension: "minecraft:the_nether", defaults: defaults)
        #expect(!nether.rememberedSlimeChunks)
        layer.regionsChanged([added])
        #expect(layer.visibleImages[region] == nil)
        layer.cancel(); await layer.waitForImages()
    }

    @Test func unavailableSeedAndOtherDimensionsHaveNoOverlayAndClosingStopsPendingWork() async {
        for (id, seed) in [("minecraft:overworld", nil), ("minecraft:the_nether", Int64(42)), ("minecraft:the_end", Int64(42))] {
            let layer = SlimeChunkLayer(dimensionID: id, seed: seed, regions: [.init(x: 0, z: 0)])
            layer.isShown = true
            await layer.waitForImages()
            #expect(!layer.isAvailable && layer.visibleImages.isEmpty && !layer.isLoading)
            layer.cancel()
        }
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: 42,
                                   regions: Set((0..<100).map { .init(x: $0, z: 0) }))
        layer.isShown = true
        layer.cancel()
        await layer.waitForImages()
        #expect(layer.visibleImages.isEmpty)
    }
}
