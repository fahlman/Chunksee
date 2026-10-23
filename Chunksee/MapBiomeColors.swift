import ChunkseeKit
import Foundation

struct WorldGameAssetSource: Equatable {
    let generation: UUID
    let version: GameAssetVersion?
}

/// Immutable color facts for one world and game archive. Dimension tabs share this value;
/// different enabled data packs never become mutable state in the shared archive reader.
nonisolated struct MapBiomeColors: Sendable {
    let sourceKey: String
    let assetSourceKey: String
    let dataVersion: Int?
    let enabledPacks: [String]
    private let definitions: [String: BiomeDefinition]
    private let colorMaps: [Identifier: ItemTexture]

    init(world: World, assetSourceKey: String, definitions: [String: BiomeDefinition],
         colorMaps: [Identifier: ItemTexture]) {
        self.assetSourceKey = assetSourceKey
        dataVersion = world.level.dataVersion
        enabledPacks = world.level.enabledDataPacks
        self.definitions = definitions
        self.colorMaps = colorMaps
        // Hash resolved values, not level.dat's timestamp: ordinary autosaves do not change
        // color meaning. Resource IDs cannot contain these field/record separators.
        let rows = definitions.keys.sorted().map { id in
            let value = definitions[id]!
            return [id, String(value.temperature.bitPattern), String(value.downfall.bitPattern),
                    String(value.waterColor), value.grassColor.map(String.init) ?? "-",
                    value.foliageColor.map(String.init) ?? "-", value.dryFoliageColor.map(String.init) ?? "-",
                    value.grassColorModifier.rawValue].joined(separator: "|")
        }
        sourceKey = CacheKey.hash(assetSourceKey + "\n" + rows.joined(separator: "\n"))
    }

    func matchesMetadata(_ world: World, assetSourceKey: String) -> Bool {
        self.assetSourceKey == assetSourceKey && dataVersion == world.level.dataVersion
            && enabledPacks == world.level.enabledDataPacks
    }

    func color(_ source: BiomeColor, biome: String?, x: Int32, z: Int32) -> UInt32? {
        guard let biome, let id = Identifier(biome), let definition = definitions[id.description] else { return nil }
        return definition.color(source, x: x, z: z) { id, pixel in
            guard let texture = colorMaps[id], texture.width == 256, texture.height == 256 else { return nil }
            return texture.rgb(at: pixel)
        }
    }
}

/// A palette entry's geometry and biome-dependent tint inputs, prepared once by the archive
/// owner. Constant and unknown tints stay with the shared block-tint resolver when drawing.
nonisolated final class MapBlockMaterial: Sendable {
    struct BiomeTint: Sendable {
        let index: Int
        let source: BiomeColor
        let yOffset: Int
    }

    let state: BlockState
    let model: AssetBlock?
    let biomeTints: [BiomeTint]

    init(state: BlockState, model: AssetBlock?, version: Int32) {
        self.state = state
        self.model = model
        let indices = Set(model?.parts.flatMap { part in
            part.alternatives.flatMap { alternative -> [Int] in
                switch alternative.model.geometry {
                case .elements(let elements): elements.flatMap { $0.faces.values.compactMap(\.tintIndex) }
                case .layers(let layers): layers.map(\.tintIndex)
                }
            }
        } ?? [])
        biomeTints = indices.sorted().compactMap { index in
            guard case .biome(let source, let offset) = state.tintSource(at: index, gameDataVersion: version) else { return nil }
            return BiomeTint(index: index, source: source, yOffset: offset)
        }
    }
}

nonisolated struct MapBlockColorRequest: Hashable, Sendable {
    struct Tint: Hashable, Sendable {
        let index: Int
        let color: UInt32
    }
    let state: BlockState
    var tints: [Tint] = []
}
