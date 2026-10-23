import ChunkseeKit
import CoreGraphics
import Foundation

/// One live jar's resources and bounded, shared picture and map-color caches. All decode/drawing
/// work is serial off-main; scrolling requests already drawn items without repeating that work.
actor GameAssetLibrary {
    nonisolated let identity = UUID()
    nonisolated let version: GameAssets.Version
    nonisolated let sourceKey: String
    private var assets: GameAssets?
    private nonisolated let caches = Caches()

    /// NSCache synchronizes get/set/eviction (Foundation's documented thread-safety contract).
    /// Values are immutable, and limits are configured
    /// before publication; only the actor inserts entries. Synchronous readers never decode.
    nonisolated private final class Caches: @unchecked Sendable {
        let models = NSCache<NSString, ModelEntry>()
        let textures = NSCache<NSString, TextureEntry>()
        let images = NSCache<NSString, CGImage>()
        let blockColors = NSCache<BlockKey, ColorEntry>()

        init() {
            models.countLimit = 512
            models.totalCostLimit = 16 * 1024 * 1024
            textures.countLimit = 512
            textures.totalCostLimit = 16 * 1024 * 1024
            blockColors.countLimit = 4096
            blockColors.totalCostLimit = 2 * 1024 * 1024
            images.countLimit = 512
            images.totalCostLimit = 8 * 1024 * 1024
        }
    }

    nonisolated private final class ModelEntry {
        let item: AssetItem?
        let tints: [[AssetItem.Tint]]

        init(_ item: AssetItem?) {
            self.item = item
            // Geometry is inspected once off-main, not on every warm lookup or inventory visit.
            tints = item?.parts.map { part in
                let used: Set<Int>
                switch part.model.geometry {
                case .layers(let layers): used = Set(layers.map(\.tintIndex))
                case .elements(let elements): used = Set(elements.flatMap { $0.faces.values.compactMap(\.tintIndex) })
                }
                return part.tints.enumerated().map { used.contains($0.offset) ? $0.element : .constant(0xFFFFFF) }
            } ?? []
        }

        func colors(for stack: ItemStack, version: GameAssets.Version,
                    texture: (Identifier) -> ItemTexture?) -> [[UInt32]]? {
            var colors: [[UInt32]] = []
            for part in tints {
                var values: [UInt32] = []
                for tint in part {
                    let value: UInt32?
                    switch tint {
                    case .constant(let color): value = color
                    case .dye(let color): value = stack.dyedColor ?? color
                    case .potion(let color): value = stack.potionColor(gameDataVersion: version.dataVersion, defaultColor: color)
                    case .firework(let color): value = color
                    case .colorMap(let id, let pixel):
                        if let image = texture(id), image.width == 256, image.height == 256 { value = image.rgb(at: pixel) }
                        else { value = nil }
                    }
                    guard let value else { return nil }
                    values.append(value)
                }
                colors.append(values)
            }
            return colors
        }

        var cost: Int {
            let geometry = item?.parts.reduce(1) { total, part in
                switch part.model.geometry {
                case .layers(let layers):
                    total + layers.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count }
                case .elements(let elements):
                    total + elements.reduce(0) { $0 + 256 + $1.faces.values.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count } }
                }
            } ?? 1
            return geometry + tints.reduce(0) { $0 + 24 + $1.count * MemoryLayout<AssetItem.Tint>.stride }
        }
    }
    nonisolated private final class TextureEntry {
        let texture: ItemTexture?
        init(_ texture: ItemTexture?) { self.texture = texture }
    }

    init(assets: GameAssets, sourceKey: String) {
        self.sourceKey = sourceKey
        self.assets = assets
        version = assets.version
    }

    /// The source owner retires this reader even when hidden tabs still retain the actor.
    /// Actor isolation lets a current synchronous draw finish before releasing its archive.
    func close() {
        assets = nil
        caches.models.removeAllObjects()
        caches.textures.removeAllObjects()
        caches.images.removeAllObjects()
        caches.blockColors.removeAllObjects()
    }

    nonisolated private final class BlockKey: NSObject {
        let state: BlockState
        init(_ state: BlockState) { self.state = state }
        override var hash: Int { state.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? BlockKey)?.state == state }
    }
    nonisolated private final class ColorEntry {
        let color: MapColor?
        init(_ color: MapColor?) { self.color = color }
    }

    /// Old renderers must not save fallback pixels under a removed source's disk key.
    func checkAvailable() throws {
        try Task.checkCancellation()
        guard assets != nil else { throw CancellationError() }
    }

    /// Only the states reached by the ordinary column scan are requested, once per chunk.
    /// Nil results are cached too; unsupported geometry keeps the map's existing fallback.
    func mapColors(for states: Set<BlockState>) throws -> [BlockState: MapColor] {
        try checkAvailable()
        guard let assets else { throw CancellationError() }
        var result: [BlockState: MapColor] = [:]
        for state in states {
            try Task.checkCancellation()
            let key = BlockKey(state)
            let entry: ColorEntry
            if let cached = caches.blockColors.object(forKey: key) { entry = cached }
            else {
                let color: MapColor?
                if let model = assets.blockModel(for: state) {
                    color = try GameModelRenderer.topColor(model, tint: { index in
                        if case .constant(let value) = state.tintSource(at: index, gameDataVersion: version.dataVersion) { return value }
                        return nil // Biome-dependent color is supplied by the separate biome-tint work.
                    }, texture: texture)
                } else { color = nil }
                entry = ColorEntry(color)
                caches.blockColors.setObject(entry, forKey: key, cost: 128 + state.description.utf8.count)
            }
            if let color = entry.color { result[state] = color }
        }
        return result
    }

    /// A warm view can draw immediately, without a placeholder frame or an actor round trip.
    /// A miss performs no I/O or decoding; the ordinary actor path handles it.
    nonisolated func cachedPicture(for stack: ItemStack) -> CGImage? {
        guard let entry = caches.models.object(forKey: stack.id as NSString), entry.item != nil,
              let colors = entry.colors(for: stack, version: version, texture: {
                  caches.textures.object(forKey: $0.description as NSString)?.texture
              }) else { return nil }
        return caches.images.object(forKey: Self.imageKey(for: stack, colors: colors))
    }

    func picture(for stack: ItemStack) throws -> CGImage? {
        try Task.checkCancellation()
        guard let assets else { return nil }
        let key = stack.id as NSString
        let entry: ModelEntry
        if let cached = caches.models.object(forKey: key) { entry = cached }
        else {
            entry = ModelEntry(assets.defaultItemModel(stack.id))
            caches.models.setObject(entry, forKey: key, cost: entry.cost)
        }
        guard let item = entry.item else { return nil }
        guard let colors = entry.colors(for: stack, version: version, texture: texture) else { return nil }
        try Task.checkCancellation()
        let imageKey = Self.imageKey(for: stack, colors: colors)
        if let image = caches.images.object(forKey: imageKey) { return image }
        guard let image = try GameModelRenderer.render(item, colors: colors, texture: texture) else { return nil }
        try Task.checkCancellation()
        caches.images.setObject(image, forKey: imageKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private nonisolated static func imageKey(for stack: ItemStack, colors: [[UInt32]]) -> NSString {
        (stack.id + "|" + colors.map { $0.map(String.init).joined(separator: ",") }.joined(separator: ";")) as NSString
    }

    private func texture(_ id: Identifier) -> ItemTexture? {
        let key = id.description as NSString
        if let cached = caches.textures.object(forKey: key) { return cached.texture }
        let decoded = assets?.texture(id.description).flatMap(ItemTexture.init(png:))
        caches.textures.setObject(TextureEntry(decoded), forKey: key, cost: decoded?.pixels.count ?? 1)
        return decoded
    }
}
