import ChunkseeKit
import CoreGraphics
import Observation
import Foundation

/// One pixel per chunk; the map scales this mask without smoothing, just like Time Spent.
nonisolated enum SlimeChunks {
    /// Translucent green, premultiplied by alpha; shared with the legend sample.
    static let pixel = (red: UInt8(20), green: UInt8(70), blue: UInt8(26), alpha: UInt8(100))

    static func image(region: RegionPosition, seed: Int64) -> CGImage? {
        guard let origin = region.chunkOrigin, let startX = Int32(exactly: origin.x),
              let startZ = Int32(exactly: origin.z),
              startX <= Int32.max - 31, startZ <= Int32.max - 31 else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for localZ in 0..<32 {
            for localX in 0..<32 where World.isSlimeChunk(x: startX + Int32(localX), z: startZ + Int32(localZ), seed: seed) {
                let index = (localZ * 32 + localX) * 4
                pixels[index] = pixel.red; pixels[index + 1] = pixel.green
                pixels[index + 2] = pixel.blue; pixels[index + 3] = pixel.alpha
            }
        }
        return CGImage.rgba(pixels, width: 32, height: 32)
    }

    static func description(at point: CGPoint, seed: Int64) -> String? {
        guard let x = Coordinates.block(point.x / 16).flatMap(Int32.init(exactly:)),
              let z = Coordinates.block(point.y / 16).flatMap(Int32.init(exactly:)) else { return nil }
        return World.isSlimeChunk(x: x, z: z, seed: seed)
            ? String(localized: "Slime chunk") : String(localized: "Not a slime chunk")
    }

    @concurrent static func images(regions: Set<RegionPosition>, seed: Int64) async -> [RegionPosition: CGImage] {
        var images: [RegionPosition: CGImage] = [:]
        for region in regions {
            guard !Task.isCancelled else { return [:] }
            images[region] = image(region: region, seed: seed)
        }
        return images
    }
}

/// The Overworld rule is independent of terrain contents: compute each saved region once,
/// reuse it through pan/zoom/export, and add masks only when new regions appear.
@Observable final class SlimeChunkLayer {
    var isShown = false {
        didSet {
            guard !isClosed, isShown != oldValue else { return }
            visibility?.rememberSlimeChunks(isShown)
            update(reread: isShown)
        }
    }
    private let readSeed: @MainActor () -> Int64?
    var seed: Int64? { readSeed() }
    var isAvailable: Bool { seed != nil }
    var isLoading: Bool { !isClosed && isAvailable && isShown && !regions.isSubset(of: loader.value?.completed ?? []) }
    var visibleImages: [RegionPosition: CGImage] {
        guard !isClosed, isShown, isAvailable else { return [:] }
        return loader.value?.images.filter { regions.contains($0.key) } ?? [:]
    }
    var visibleSeed: Int64? { isShown ? seed : nil }

    private var regions: Set<RegionPosition>
    @ObservationIgnored private var visibility: LayerVisibility?
    private let loader: RefreshLoader<Int64?, Set<RegionPosition>, Masks>
    @ObservationIgnored private var seedObservation: ModelObservation?
    private var isClosed: Bool { loader.isClosed || loader.work.isClosed }

    nonisolated private struct Masks: Sendable {
        var completed: Set<RegionPosition> = []
        var images: [RegionPosition: CGImage] = [:]
    }

    init(dimensionID: String?, seed: @escaping @MainActor () -> Int64?, regions: Set<RegionPosition>, work: BackgroundWork,
         readImages: @escaping @Sendable (Set<RegionPosition>, Int64) async -> [RegionPosition: CGImage] = SlimeChunks.images) {
        readSeed = { dimensionID == "minecraft:overworld" ? seed() : nil }
        self.regions = regions
        loader = RefreshLoader(work: work, priority: nil, whenInactive: .cancel,
            source: dimensionID == "minecraft:overworld" ? seed() : nil,
            firstRequest: regions, merge: { _, current in current }) { seed, regions, previous in
                guard let seed else { return Masks() }
                var next = previous ?? Masks()
                next.completed.formIntersection(regions)
                next.images = next.images.filter { regions.contains($0.key) }
                let missing = regions.subtracting(next.completed)
                guard !missing.isEmpty else { return next }
                let images = await readImages(missing, seed)
                try Task.checkCancellation()
                next.images.merge(images.filter { regions.contains($0.key) }) { _, new in new }
                next.completed.formUnion(missing)
                return next
            }
        observeSeed()
    }

    /// The world snapshot and this accessor are main-actor isolated. Invalidate synchronously
    /// so neither a drawn mask nor a late read can describe the previous seed.
    private func observeSeed() {
        seedObservation = ModelObservation(self, isActive: { !$0.isClosed }, read: {
            $0.seed
        }) { layer, previous in
            guard layer.seed != previous else { return }
            layer.update(reread: true)
        }
    }

    func restoreVisibility(from visibility: LayerVisibility) {
        self.visibility = visibility
        isShown = visibility.rememberedSlimeChunks
    }

    func regionsChanged(_ regions: Set<RegionPosition>) {
        guard !isClosed else { return }
        self.regions = regions
        update(reread: true)
    }

    private func update(reread: Bool) {
        guard !isClosed else { return }
        loader.request(source: seed, isEnabled: isShown && isAvailable, refresh: reread ? regions : nil)
    }

    func cancel() { seedObservation?.cancel(); loader.close() }
    func waitForImages() async { await loader.waitUntilFinished() }
}
