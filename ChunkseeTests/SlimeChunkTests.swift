import ChunkseeKit
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SlimeChunkTests {
    @Observable final class Seed {
        var value: Int64? = 42
    }
    final class SeedReads { var count = 0 }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func closingTheLayerOrWorldStopsReadingSeedChanges(closeWorld: Bool) async throws {
        let seed = Seed(), reads = SeedReads(), work = BackgroundWork()
        let region = RegionPosition(x: 0, z: 0)
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: {
            reads.count += 1
            return seed.value
        }, regions: [region], work: work)
        layer.isShown = true
        await layer.waitForImages()
        _ = try #require(layer.visibleImages[region])
        if closeWorld { work.close() } else { layer.cancel() }
        await layer.waitForImages()
        let before = reads.count
        #expect(before > 0)
        seed.value = 43
        seed.value = nil
        seed.value = 44
        #expect(reads.count == before)
        layer.cancel(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func changingTheSavedSeedRejectsOldMasksAndRestoresAfterRemoval() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork(), seed = Seed()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { seed.value }, regions: [region], work: work,
                                   readImages: { _, seed in await gate.read(String(seed)) })
        layer.isShown = true
        await gate.waitForRequest("42")
        seed.value = 43
        await gate.waitForCancellation("42")
        let old = try #require(SlimeChunks.image(region: region, seed: 42))
        await gate.finish("42", with: [region: old])
        await gate.waitForRequest("43")
        #expect(layer.visibleImages.isEmpty && layer.visibleSeed == 43)
        let current = try #require(SlimeChunks.image(region: region, seed: 43))
        await gate.finish("43", with: [region: current])
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === current)
        seed.value = nil
        #expect(!layer.isAvailable && layer.visibleImages.isEmpty)
        seed.value = 43
        await gate.waitForRequest("43", count: 2)
        await gate.finish("43", with: [region: current])
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === current)
        #expect(await gate.requested == ["42", "43", "43"])
        layer.cancel(); work.close(); await work.waitUntilFinished()
    }

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
        let defaults = TestDefaults.make(), world = UUID()
        let visibility = LayerVisibility(settings: WorldSettings(id: world, defaults: defaults), dimension: "minecraft:overworld")
        let region = RegionPosition(x: 0, z: 0), added = RegionPosition(x: -1, z: 0)
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, regions: [region], work: BackgroundWork())
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
        let restored = LayerVisibility(settings: WorldSettings(id: world, defaults: defaults), dimension: "minecraft:overworld")
        #expect(restored.rememberedSlimeChunks)
        let nether = LayerVisibility(settings: WorldSettings(id: world, defaults: defaults), dimension: "minecraft:the_nether")
        #expect(!nether.rememberedSlimeChunks)
        layer.regionsChanged([added])
        #expect(layer.visibleImages[region] == nil)
        layer.cancel(); await layer.waitForImages()
    }

    @Test func unavailableSeedAndOtherDimensionsHaveNoOverlayAndClosingStopsPendingWork() async {
        for (id, seed) in [("minecraft:overworld", nil), ("minecraft:the_nether", Int64(42)), ("minecraft:the_end", Int64(42))] {
            let layer = SlimeChunkLayer(dimensionID: id, seed: { seed }, regions: [.init(x: 0, z: 0)], work: BackgroundWork())
            layer.isShown = true
            await layer.waitForImages()
            #expect(!layer.isAvailable && layer.visibleImages.isEmpty && !layer.isLoading)
            layer.cancel()
        }
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 },
                                   regions: Set((0..<100).map { .init(x: $0, z: 0) }), work: BackgroundWork())
        layer.isShown = true
        layer.cancel()
        await layer.waitForImages()
        #expect(layer.visibleImages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func worldCloseRejectsLateMasksAndNewWork() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, regions: [region], work: work,
                                   readImages: { _, _ in await gate.read("pending") })
        layer.isShown = true
        await gate.waitForRequest("pending")
        work.close()
        await gate.waitForCancellation("pending")
        let image = try #require(SlimeChunks.image(region: region, seed: 42))
        await gate.finish("pending", with: [region: image])
        await work.waitUntilFinished()
        #expect(layer.visibleImages.isEmpty)
        layer.regionsChanged([region, .init(x: 1, z: 0)])
        layer.isShown = false
        layer.isShown = true
        await layer.waitForImages()
        #expect(await gate.requested == ["pending"])
    }

    @Test(.timeLimit(.minutes(1))) func hidingThenShowingRestartsCanceledWorkWithTheCurrentRegions() async throws {
        let first = RegionPosition(x: 0, z: 0), added = RegionPosition(x: 1, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, regions: [first], work: work,
                                   readImages: { regions, _ in await gate.read("\(regions.count)") })
        layer.isShown = true
        await gate.waitForRequest("1")
        layer.isShown = false
        await gate.waitForCancellation("1")
        layer.regionsChanged([first, added])
        layer.isShown = true
        let firstImage = try #require(SlimeChunks.image(region: first, seed: 42))
        let addedImage = try #require(SlimeChunks.image(region: added, seed: 42))
        await gate.finish("1", with: [first: firstImage])
        await gate.waitForRequest("2")
        #expect(layer.visibleImages.isEmpty)
        await gate.finish("2", with: [first: firstImage, added: addedImage])
        await layer.waitForImages()
        #expect(layer.visibleImages[first] === firstImage)
        #expect(layer.visibleImages[added] === addedImage)
        #expect(!layer.isLoading && !work.isClosed)
        #expect(await gate.requested == ["1", "2"])
        work.close()
        await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneLayerLeavesItsSiblingRunning() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let first = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, regions: [region], work: work,
                                   readImages: { _, _ in await gate.read("first") })
        let second = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, regions: [region], work: work,
                                    readImages: { _, _ in await gate.read("second") })
        first.isShown = true
        second.isShown = true
        await gate.waitForRequest("first")
        await gate.waitForRequest("second")
        first.cancel()
        await gate.waitForCancellation("first")
        let image = try #require(SlimeChunks.image(region: region, seed: 42))
        await gate.finish("first", with: [region: image])
        await first.waitForImages() // The sibling is deliberately still held.
        #expect(first.visibleImages.isEmpty && !work.isClosed)
        await gate.finish("second", with: [region: image])
        await second.waitForImages()
        #expect(second.visibleImages[region] === image)
        work.close()
        await work.waitUntilFinished()
    }
}
