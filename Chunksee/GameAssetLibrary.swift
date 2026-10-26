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
        let models = NSCache<ItemKey, ModelEntry>()
        let textures = NSCache<NSString, TextureEntry>()
        let images = NSCache<ItemKey, CGImage>()
        let blockMaterials = NSCache<BlockKey, MapBlockMaterial>()
        let blockColors = NSCache<BlockKey, ColorEntry>()
        let blockTextures = NSCache<BlockPictureKey, TextureEntry>()

        init() {
            models.countLimit = 512
            models.totalCostLimit = 16 * 1024 * 1024
            textures.countLimit = 512
            textures.totalCostLimit = 16 * 1024 * 1024
            blockTextures.countLimit = 4096
            blockTextures.totalCostLimit = 16 * 1024 * 1024
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

    /// Kit owns every saved fact that can choose a model. Keep that complete value in both
    /// caches instead of rebuilding a partial identity from selected fields in the app.
    nonisolated private final class ItemKey: NSObject {
        let selection: ItemModelSelection
        let colors: [[UInt32]]

        init(_ selection: ItemModelSelection, colors: [[UInt32]] = []) {
            self.selection = selection
            self.colors = colors
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(selection)
            hasher.combine(colors)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ItemKey else { return false }
            return selection == other.selection && colors == other.colors
        }

        /// Conservatively charge retained strings/arrays to each cache, even when Swift shares
        /// their storage. Only insertions need this accounting; warm lookups do not repeat it.
        var cost: Int {
            let data = selection.customModelData
            let design = selection.bannerDesign
            let patternBytes = design.layers.reduce(0) { total, layer in
                let strings = switch layer.pattern {
                case .reference(let id): id.description.utf8.count
                case .inline(let asset, let key): asset.description.utf8.count + key.utf8.count
                }
                return total + 64 + strings
            }
            let pot = selection.potDecorations
            let potBytes = [pot.back, pot.left, pot.right, pot.front].reduce(0) { total, decoration in
                guard let decoration else { return total }
                let patternBytes = switch decoration.pattern {
                case .itemDefault, .removed: 0
                case .reference(let id), .inline(let id): id.description.utf8.count
                }
                return total + 96 + decoration.itemID.description.utf8.count + patternBytes
            }
            let headBytes = switch selection.headSkin {
            case .defaultSkin, .unresolved: 0
            case .resource(let id): 64 + id.description.utf8.count
            }
            return 128 + selection.modelID.description.utf8.count + (selection.trimMaterialID?.description.utf8.count ?? 0)
                + data.floats.count * MemoryLayout<Float>.stride + data.flags.count * MemoryLayout<Bool>.stride
                + data.colors.count * MemoryLayout<UInt32>.stride
                + data.strings.reduce(0) { $0 + 32 + $1.utf8.count }
                + patternBytes + potBytes + headBytes + selection.savedPropertyStorageCost
                + colors.reduce(0) { $0 + 32 + $1.count * MemoryLayout<UInt32>.stride }
        }
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
        caches.blockTextures.removeAllObjects()
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

    /// Position chooses the models, not a new cache entry for every world coordinate. Equal
    /// chosen geometry/turns and tints share one picture across columns, chunks and windows.
    nonisolated private final class BlockPictureKey: NSObject {
        struct Choice: Hashable {
            let id: Identifier
            let rotation: SIMD3<Int>
            let uvLock: Bool
        }
        let request: MapBlockColorRequest
        let choices: [Choice]
        init(_ request: MapBlockColorRequest, alternatives: [AssetBlock.Alternative]) {
            self.request = request
            choices = alternatives.map { Choice(id: $0.modelID, rotation: $0.rotation, uvLock: $0.uvLock) }
        }
        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(request); hasher.combine(choices)
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? BlockPictureKey else { return false }
            return request == other.request && choices == other.choices
        }
        var cost: Int {
            256 + request.state.description.utf8.count + request.state.properties.count * 64
                + request.tints.count * 16 + choices.reduce(0) { $0 + 64 + $1.id.description.utf8.count }
        }
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
                    color = try GameModelRenderer.topColor(model, tint: { tint($0, for: request) }, texture: texture)
                } else { color = nil }
                entry = ColorEntry(color)
                caches.blockColors.setObject(entry, forKey: key, cost: 128 + request.state.description.utf8.count + request.tints.count * 16)
            }
            result.append(entry.color)
        }
        return result
    }

    private func tint(_ index: Int, for request: MapBlockColorRequest) -> UInt32? {
        if let value = request.tints.color(at: index) { return value }
        if case .constant(let value) = request.state.tintSource(at: index) { return value }
        return nil
    }

    /// One batch for a chunk's retained palette. Kit chooses each position's actual variants;
    /// the same source, model, tint, decoded texture and rasterizer owners draw their pixels.
    func mapTextures(requests: [MapBlockColorRequest], indices: [UInt16], positions: [BlockPosition?]) throws -> [ItemTexture?] {
        try checkAvailable()
        guard requests.count <= 256, indices.count == 256, positions.count == 256 else { return [] }
        let models = requests.map { material(for: $0.state).model }
        return try positions.enumerated().map { index, position in
            try Task.checkCancellation()
            let paletteIndex = Int(indices[index])
            guard let position, requests.indices.contains(paletteIndex),
                  let alternatives = models[paletteIndex]?.selectedAlternatives(at: position) else { return nil }
            let request = requests[paletteIndex], key = BlockPictureKey(request, alternatives: alternatives)
            if let cached = caches.blockTextures.object(forKey: key) { return cached.texture }
            let image = try GameModelRenderer.topTexture(alternatives, tint: { tint($0, for: request) }, texture: texture)
            caches.blockTextures.setObject(TextureEntry(image), forKey: key, cost: key.cost + (image?.pixels.count ?? 1))
            return image
        }
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
        let material = MapBlockMaterial(state: state, model: assets?.blockModel(for: state))
        let cost = material.model?.parts.reduce(1) { total, part in
            total + part.alternatives.reduce(0) { $0 + Self.modelCost($1.model) }
        } ?? 1
        caches.blockMaterials.setObject(material, forKey: key, cost: cost + material.biomeTints.count * 32)
        return material
    }

    private nonisolated static func modelCost(_ model: AssetModel) -> Int {
        func materialCost(_ material: AssetModel.Material) -> Int {
            128 + material.texture.description.utf8.count
                + material.overlays.reduce(0) { $0 + 64 + $1.texture.description.utf8.count }
        }
        switch model.geometry {
        case .layers(let layers): return layers.reduce(0) { $0 + materialCost($1.material) }
        case .elements(let elements):
            return elements.reduce(0) { $0 + 256 + $1.faces.values.reduce(0) { $0 + materialCost($1.material) } }
        }
    }

    func lighting(in world: World) throws -> [String: MapLighting] {
        try checkAvailable()
        return try MapLighting.read(in: world, assets: assets)
    }

    func definitions(in world: World) throws -> WorldDefinitions {
        try checkAvailable()
        return try WorldDefinitions.read(world, assets: assets)
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
        return try MapBiomeColors(world: world, assetSourceKey: sourceKey, definitions: definitions, colorMaps: maps)
    }

    func nightLighting(in world: World) throws -> [String: MonsterSpawnLight] {
        try checkAvailable()
        return try world.nightMonsterLighting(assets: assets)
    }

    /// A warm view can draw immediately, without a placeholder frame or an actor round trip.
    /// A miss performs no I/O or decoding; the ordinary actor path handles it.
    nonisolated func cachedPicture(for stack: ItemStack) -> CGImage? {
        guard let selection = stack.itemModelSelection,
              let entry = caches.models.object(forKey: ItemKey(selection)), entry.item != nil,
              let colors = entry.colors(for: stack, version: version, texture: {
                  caches.textures.object(forKey: $0.description as NSString)?.texture
              }) else { return nil }
        return caches.images.object(forKey: ItemKey(selection, colors: colors))
    }

    func picture(for stack: ItemStack) throws -> CGImage? {
        try Task.checkCancellation()
        guard let assets, let selection = stack.itemModelSelection else { return nil }
        let key = ItemKey(selection)
        let entry: ModelEntry
        if let cached = caches.models.object(forKey: key) { entry = cached }
        else {
            entry = ModelEntry(assets.itemModel(for: selection))
            let cost = entry.cost + key.cost
            if cost <= caches.models.totalCostLimit {
                caches.models.setObject(entry, forKey: key, cost: cost)
            }
        }
        guard let item = entry.item else { return nil }
        guard let colors = entry.colors(for: stack, version: version, texture: texture) else { return nil }
        try Task.checkCancellation()
        let imageKey = ItemKey(selection, colors: colors)
        if let image = caches.images.object(forKey: imageKey) { return image }
        guard let image = try GameModelRenderer.render(item, colors: colors, texture: itemTexture) else { return nil }
        try Task.checkCancellation()
        let cost = image.bytesPerRow * image.height + imageKey.cost
        if cost <= caches.images.totalCostLimit {
            caches.images.setObject(image, forKey: imageKey, cost: cost)
        }
        return image
    }

    /// Atlas sprites have their own identity: a generated item sprite must neither replace
    /// a direct colormap read nor bypass a later atlas source with the same resource name.
    private func itemTexture(_ id: Identifier) -> ItemTexture? {
        let key = ("items|" + id.description) as NSString
        if let cached = caches.textures.object(forKey: key) { return cached.texture }
        let decoded: ItemTexture?
        if let source = assets?.palettedTexture(id.description, in: "minecraft:items") {
            if let base = assets?.texture(source.texture.description),
               let key = assets?.texture(source.paletteKey.description),
               let palette = assets?.texture(source.palette.description) {
                decoded = ItemTexture(png: base, paletteKey: key, palette: palette)
            } else { decoded = nil }
        } else { decoded = texture(id) }
        caches.textures.setObject(TextureEntry(decoded), forKey: key, cost: decoded?.pixels.count ?? 1)
        return decoded
    }

    private func texture(_ id: Identifier) -> ItemTexture? {
        let key = id.description as NSString
        if let cached = caches.textures.object(forKey: key) { return cached.texture }
        let decoded = assets?.texture(id.description).flatMap(ItemTexture.init(png:))
        caches.textures.setObject(TextureEntry(decoded), forKey: key, cost: decoded?.pixels.count ?? 1)
        return decoded
    }
}
