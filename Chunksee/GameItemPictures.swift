import ChunkseeKit
import CoreGraphics
import Foundation

/// One live jar's immutable resources and bounded, shared thumbnail caches. All decode/drawing
/// work is serial off-main; scrolling requests already drawn items without repeating that work.
actor GameItemPictures {
    nonisolated let identity = UUID()
    nonisolated let version: GameAssets.Version
    private let assets: GameAssets
    private let models = NSCache<NSString, ModelEntry>()
    private let textures = NSCache<NSString, TextureEntry>()
    private let images = NSCache<NSString, CGImage>()

    nonisolated private final class ModelEntry {
        let item: AssetItem?
        init(_ item: AssetItem?) { self.item = item }
        var cost: Int {
            item?.parts.reduce(1) { total, part in
                switch part.model.geometry {
                case .layers(let layers):
                    total + layers.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count }
                case .elements(let elements):
                    total + elements.reduce(0) { $0 + 256 + $1.faces.values.reduce(0) { $0 + 128 + $1.material.texture.description.utf8.count } }
                }
            } ?? 1
        }
    }
    nonisolated private final class TextureEntry {
        let texture: ItemTexture?
        init(_ texture: ItemTexture?) { self.texture = texture }
    }

    init(assets: GameAssets) {
        self.assets = assets
        version = assets.version
        models.countLimit = 512
        models.totalCostLimit = 16 * 1024 * 1024
        textures.countLimit = 512
        textures.totalCostLimit = 16 * 1024 * 1024
        images.countLimit = 512
        images.totalCostLimit = 8 * 1024 * 1024
    }

    func picture(for stack: ItemStack) throws -> CGImage? {
        try Task.checkCancellation()
        let key = stack.id as NSString
        let entry: ModelEntry
        if let cached = models.object(forKey: key) { entry = cached }
        else {
            entry = ModelEntry(assets.defaultItemModel(stack.id))
            models.setObject(entry, forKey: key, cost: entry.cost)
        }
        guard let item = entry.item else { return nil }
        var colors: [[UInt32]] = []
        for part in item.parts {
            try Task.checkCancellation()
            let usedTints: Set<Int>
            switch part.model.geometry {
            case .layers(let layers): usedTints = Set(layers.map(\.tintIndex))
            case .elements(let elements): usedTints = Set(elements.flatMap { $0.faces.values.compactMap(\.tintIndex) })
            }
            var values: [UInt32] = []
            for (index, tint) in part.tints.enumerated() {
                guard usedTints.contains(index) else { values.append(0xFFFFFF); continue }
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
        let imageKey = (stack.id + "|" + colors.map { $0.map(String.init).joined(separator: ",") }.joined(separator: ";")) as NSString
        if let image = images.object(forKey: imageKey) { return image }
        guard let image = try ItemPictureRenderer.render(item, colors: colors, texture: texture) else { return nil }
        try Task.checkCancellation()
        images.setObject(image, forKey: imageKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private func texture(_ id: Identifier) -> ItemTexture? {
        let key = id.description as NSString
        if let cached = textures.object(forKey: key) { return cached.texture }
        let decoded = assets.texture(id.description).flatMap(ItemTexture.init(png:))
        textures.setObject(TextureEntry(decoded), forKey: key, cost: decoded?.pixels.count ?? 1)
        return decoded
    }
}
