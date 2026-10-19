import ChunkseeKit
import CoreGraphics
import Observation
import Foundation

/// One pixel per chunk; the map scales this mask without smoothing, just like Time Spent.
nonisolated enum SlimeChunks {
    static func image(region: RegionPosition, seed: Int64) -> CGImage? {
        guard let origin = region.chunkOrigin, let startX = Int32(exactly: origin.x),
              let startZ = Int32(exactly: origin.z),
              startX <= Int32.max - 31, startZ <= Int32.max - 31 else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for localZ in 0..<32 {
            for localX in 0..<32 where World.isSlimeChunk(x: startX + Int32(localX), z: startZ + Int32(localZ), seed: seed) {
                let index = (localZ * 32 + localX) * 4
                // Translucent green, premultiplied by alpha; visible over light and dark terrain.
                pixels[index] = 20; pixels[index + 1] = 70; pixels[index + 2] = 26; pixels[index + 3] = 100
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
            if isShown { load() } else { task?.cancel() }
        }
    }
    let seed: Int64?
    var isAvailable: Bool { seed != nil }
    var isLoading: Bool { isAvailable && isShown && !regions.isSubset(of: completed) }
    var visibleImages: [RegionPosition: CGImage] { isShown && isAvailable ? images : [:] }
    var visibleSeed: Int64? { isShown ? seed : nil }

    private var regions: Set<RegionPosition>
    private var completed: Set<RegionPosition> = []
    private var images: [RegionPosition: CGImage] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var visibility: LayerVisibility?
    private var isClosed = false

    init(dimensionID: String?, seed: Int64?, regions: Set<RegionPosition>) {
        self.seed = dimensionID == "minecraft:overworld" ? seed : nil
        self.regions = regions
    }

    func restoreVisibility(from visibility: LayerVisibility) {
        self.visibility = visibility
        isShown = visibility.rememberedSlimeChunks
    }

    func regionsChanged(_ regions: Set<RegionPosition>) {
        guard !isClosed else { return }
        self.regions = regions
        completed.formIntersection(regions)
        images = images.filter { regions.contains($0.key) }
        load()
    }

    private func load() {
        guard !isClosed, isShown, let seed, task == nil else { return }
        let missing = regions.subtracting(completed)
        guard !missing.isEmpty else { return }
        task = Task { [weak self] in
            defer { self?.task = nil; self?.load() }
            let images = await SlimeChunks.images(regions: missing, seed: seed)
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.images.merge(images.filter { self.regions.contains($0.key) }) { _, new in new }
            self.completed.formUnion(missing.intersection(self.regions))
        }
    }

    func cancel() { isClosed = true; task?.cancel() }
    func waitForImages() async { while let task { await task.value } }
}
