import ChunkseeKit
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct SlimeChunkTests {
    @Observable final class Visibility { var isShown = false }

    @Observable final class Seed {
        var value: Int64? = 42
    }

    @Test(.timeLimit(.minutes(1))) func changingTheSavedSeedRejectsOldMasksAndRestoresAfterRemoval() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork(), seed = Seed()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { seed.value }, isShown: { visibility.isShown }, regions: [region], work: work,
                                   readImages: { _, seed in await gate.read(String(seed)) })
        visibility.isShown = true
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

    @Test func imagesAreReusedAndNewRegionsAreAddedWhenShownAgain() async throws {
        let region = RegionPosition(x: 0, z: 0), added = RegionPosition(x: -1, z: 0)
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { visibility.isShown }, regions: [region], work: BackgroundWork())
        #expect(!layer.isShown && layer.visibleImages.isEmpty)
        visibility.isShown = true
        await layer.waitForImages()
        let image = try #require(layer.visibleImages[region])
        layer.regionsChanged([region, added])
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === image)
        #expect(layer.visibleImages[added] != nil)
        visibility.isShown = false
        #expect(layer.visibleImages.isEmpty)
        visibility.isShown = true
        await layer.waitForImages()
        #expect(layer.visibleImages[region] === image)
        layer.regionsChanged([added])
        #expect(layer.visibleImages[region] == nil)
        layer.cancel(); await layer.waitForImages()
    }

    @Test func unavailableSeedAndOtherDimensionsHaveNoOverlayAndClosingStopsPendingWork() async {
        for (id, seed) in [("minecraft:overworld", nil), ("minecraft:the_nether", Int64(42)), ("minecraft:the_end", Int64(42))] {
            let visibility = Visibility()
            let layer = SlimeChunkLayer(dimensionID: id, seed: { seed }, isShown: { visibility.isShown }, regions: [.init(x: 0, z: 0)], work: BackgroundWork())
            visibility.isShown = true
            await layer.waitForImages()
            #expect(!layer.isAvailable && layer.visibleImages.isEmpty && !layer.isLoading)
            layer.cancel()
        }
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 },
                                   isShown: { visibility.isShown }, regions: Set((0..<100).map { .init(x: $0, z: 0) }), work: BackgroundWork())
        visibility.isShown = true
        layer.cancel()
        await layer.waitForImages()
        #expect(layer.visibleImages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func worldCloseRejectsLateMasksAndNewWork() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { visibility.isShown }, regions: [region], work: work,
                                   readImages: { _, _ in await gate.read("pending") })
        visibility.isShown = true
        await gate.waitForRequest("pending")
        work.close()
        await gate.waitForCancellation("pending")
        let image = try #require(SlimeChunks.image(region: region, seed: 42))
        await gate.finish("pending", with: [region: image])
        await work.waitUntilFinished()
        #expect(layer.visibleImages.isEmpty)
        layer.regionsChanged([region, .init(x: 1, z: 0)])
        visibility.isShown = false
        visibility.isShown = true
        await layer.waitForImages()
        #expect(await gate.requested == ["pending"])
    }

    @Test(.timeLimit(.minutes(1))) func hidingThenShowingRestartsCanceledWorkWithTheCurrentRegions() async throws {
        let first = RegionPosition(x: 0, z: 0), added = RegionPosition(x: 1, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { visibility.isShown }, regions: [first], work: work,
                                   readImages: { regions, _ in await gate.read("\(regions.count)") })
        visibility.isShown = true
        await gate.waitForRequest("1")
        visibility.isShown = false
        await gate.waitForCancellation("1")
        layer.regionsChanged([first, added])
        visibility.isShown = true
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

    @Test(.timeLimit(.minutes(1))) func regionChangesDuringAReadKeepProgressAndComputeOnlyMissingMasks() async throws {
        let first = RegionPosition(x: 0, z: 0), removed = RegionPosition(x: 1, z: 0), last = RegionPosition(x: 2, z: 0)
        let firstImage = try #require(SlimeChunks.image(region: first, seed: 42))
        let removedImage = try #require(SlimeChunks.image(region: removed, seed: 42))
        let lastImage = try #require(SlimeChunks.image(region: last, seed: 42))
        let work = BackgroundWork(), gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let visibility = Visibility()
        let layer = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { visibility.isShown }, regions: [first], work: work,
            readImages: { regions, _ in await gate.read(regions.map { String($0.x) }.sorted().joined(separator: ",")) })
        visibility.isShown = true
        await gate.waitForRequest("0")
        layer.regionsChanged([first, removed])
        layer.regionsChanged([first, removed, last])
        await gate.finish("0", with: [first: firstImage])
        await gate.waitForRequest("1,2")
        #expect(layer.visibleImages[first] === firstImage && layer.isLoading)
        layer.regionsChanged([first, last])
        await gate.releaseAllAndFuture(with: [removed: removedImage, last: lastImage])
        await layer.waitForImages()
        #expect(await gate.requested == ["0", "1,2"])
        #expect(layer.visibleImages[first] === firstImage && layer.visibleImages[last] === lastImage)
        #expect(layer.visibleImages[removed] == nil && !layer.isLoading)
        layer.cancel(); work.close(); await work.waitUntilFinished()
    }

    @Test(.timeLimit(.minutes(1))) func closingOneLayerLeavesItsSiblingRunning() async throws {
        let region = RegionPosition(x: 0, z: 0), work = BackgroundWork()
        let gate = AsyncReadGate<[RegionPosition: CGImage]>()
        let firstVisibility = Visibility()
        let first = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { firstVisibility.isShown }, regions: [region], work: work,
                                   readImages: { _, _ in await gate.read("first") })
        let secondVisibility = Visibility()
        let second = SlimeChunkLayer(dimensionID: "minecraft:overworld", seed: { 42 }, isShown: { secondVisibility.isShown }, regions: [region], work: work,
                                    readImages: { _, _ in await gate.read("second") })
        firstVisibility.isShown = true
        secondVisibility.isShown = true
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
