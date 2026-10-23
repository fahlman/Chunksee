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
        let blockMaterials = NSCache<BlockKey, MapBlockMaterial>()
        let blockColors = NSCache<BlockKey, ColorEntry>()

        init() {
            models.countLimit = 512
            models.totalCostLimit = 16 * 1024 * 1024
            textures.countLimit = 512
            textures.totalCostLimit = 16 * 1024 * 1024
            blockColors.countLimit = 4096
            blockColors.totalCostLimit = 2 * 1024 * 1024
            blockMaterials.countLimit = 512
            blockMaterials.totalCostLimit = 16 * 1024 * 1024
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
            let geometry = item?.parts.reduce(1) { $0 + GameAssetLibrary.modelCost($1.model) } ?? 1
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
        caches.blockMaterials.removeAllObjects()
        caches.blockColors.removeAllObjects()
    }

    nonisolated private final class BlockKey: NSObject {
        let request: MapBlockColorRequest
        init(_ state: BlockState) { request = MapBlockColorRequest(state: state) }
        init(_ request: MapBlockColorRequest) { self.request = request }
        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? BlockKey)?.request == request }
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

    /// The renderer checks source availability at region boundaries. Warm chunk lookups read
    /// immutable cache entries directly; a missing entry goes through the actor to decode it.
    /// An inner nil is a cached unsupported model, not a cache miss.
    nonisolated func cachedMapColors(for states: [BlockState]) -> [MapColor?]? {
        cachedMapColors(requests: states.map { MapBlockColorRequest(state: $0) })
    }

    nonisolated func cachedMapColors(requests: [MapBlockColorRequest]) -> [MapColor?]? {
        var result: [MapColor?] = []
        result.reserveCapacity(requests.count)
        for request in requests {
            guard let entry = caches.blockColors.object(forKey: BlockKey(request)) else { return nil }
            result.append(entry.color)
        }
        return result
    }

    /// Results retain input order, including repeated states and unavailable colors. The
    /// renderer indexes them by palette entry instead of hashing full states for every column.
    func mapColors(for states: [BlockState]) throws -> [MapColor?] {
        try mapColors(requests: states.map { MapBlockColorRequest(state: $0) })
    }

    func mapColors(requests: [MapBlockColorRequest]) throws -> [MapColor?] {
        try checkAvailable()
        var result: [MapColor?] = []
        result.reserveCapacity(requests.count)
        for request in requests {
            try Task.checkCancellation()
            let key = BlockKey(request)
            let entry: ColorEntry
            if let cached = caches.blockColors.object(forKey: key) { entry = cached }
            else {
                let color: MapColor?
                if let model = material(for: request.state).model {
                    color = try GameModelRenderer.topColor(model, tint: { index in
                        if let value = request.tints.color(at: index) { return value }
                        if case .constant(let value) = request.state.tintSource(at: index, gameDataVersion: version.dataVersion) { return value }
                        return nil
                    }, texture: texture)
                } else { color = nil }
                entry = ColorEntry(color)
                caches.blockColors.setObject(entry, forKey: key, cost: 128 + request.state.description.utf8.count + request.tints.count * 16)
            }
            result.append(entry.color)
        }
        return result
    }

    nonisolated func cachedMapMaterials(for states: [BlockState]) -> [MapBlockMaterial]? {
        var result: [MapBlockMaterial] = []
        result.reserveCapacity(states.count)
        for state in states {
            guard let entry = caches.blockMaterials.object(forKey: BlockKey(state)) else { return nil }
            result.append(entry)
        }
        return result
    }

    func mapMaterials(for states: [BlockState]) throws -> [MapBlockMaterial] {
        try checkAvailable()
        return try states.map { state in
            try Task.checkCancellation()
            return material(for: state)
        }
    }

    private func material(for state: BlockState) -> MapBlockMaterial {
        let key = BlockKey(state)
        if let cached = caches.blockMaterials.object(forKey: key) { return cached }
        let material = MapBlockMaterial(state: state, model: assets?.blockModel(for: state), version: version.dataVersion)
        let cost = material.model?.parts.reduce(1) { total, part in
            total + part.alternatives.reduce(0) { $0 + Self.modelCost($1.model) }
        } ?? 1
        caches.blockMaterials.setObject(material, forKey: key, cost: cost + material.biomeTints.count * 32)
        return material
    }

    private nonisolated static func modelCost(_ model: AssetModel) -> Int {
        switch model.geometry {
        case .layers(let layers): layers.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count }
        case .elements(let elements):
            elements.reduce(0) { $0 + 256 + $1.faces.values.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count } }
        }
    }

    /// Reads world-specific metadata through Kit and shares the same decoded colormap pixels
    /// used by item pictures. The caller owns the snapshot and its refresh lifetime.
    func biomeColors(in world: World) throws -> MapBiomeColors {
        try checkAvailable()
        let definitions = try world.biomeDefinitions(assets: assets)
        var maps: [Identifier: ItemTexture] = [:]
        for name in ["grass", "foliage", "dry_foliage"] {
            try Task.checkCancellation()
            if let id = Identifier(namespace: "minecraft", path: "colormap/" + name), let value = texture(id) { maps[id] = value }
        }
        return MapBiomeColors(world: world, assetSourceKey: sourceKey, definitions: definitions, colorMaps: maps)
    }

    /// A warm view can draw immediately, without a placeholder frame or an actor round trip.
    /// A miss performs no I/O or decoding; the ordinary actor path handles it.
    nonisolated func cachedPicture(for stack: ItemStack) -> CGImage? {
        guard let model = stack.itemModelID,
              let entry = caches.models.object(forKey: model.description as NSString), entry.item != nil,
              let colors = entry.colors(for: stack, version: version, texture: {
                  caches.textures.object(forKey: $0.description as NSString)?.texture
              }) else { return nil }
        return caches.images.object(forKey: Self.imageKey(for: model, colors: colors))
    }

    func picture(for stack: ItemStack) throws -> CGImage? {
        try Task.checkCancellation()
        guard let assets, let model = stack.itemModelID else { return nil }
        let key = model.description as NSString
        let entry: ModelEntry
        if let cached = caches.models.object(forKey: key) { entry = cached }
        else {
            entry = ModelEntry(assets.defaultItemModel(model.description))
            caches.models.setObject(entry, forKey: key, cost: entry.cost)
        }
        guard let item = entry.item else { return nil }
        guard let colors = entry.colors(for: stack, version: version, texture: texture) else { return nil }
        try Task.checkCancellation()
        let imageKey = Self.imageKey(for: model, colors: colors)
        if let image = caches.images.object(forKey: imageKey) { return image }
        guard let image = try GameModelRenderer.render(item, colors: colors, texture: texture) else { return nil }
        try Task.checkCancellation()
        caches.images.setObject(image, forKey: imageKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private nonisolated static func imageKey(for model: Identifier, colors: [[UInt32]]) -> NSString {
        (model.description + "|" + colors.map { $0.map(String.init).joined(separator: ",") }.joined(separator: ";")) as NSString
    }

    private func texture(_ id: Identifier) -> ItemTexture? {
        let key = id.description as NSString
        if let cached = caches.textures.object(forKey: key) { return cached.texture }
        let decoded = assets?.texture(id.description).flatMap(ItemTexture.init(png:))
        caches.textures.setObject(TextureEntry(decoded), forKey: key, cost: decoded?.pixels.count ?? 1)
        return decoded
    }
}
