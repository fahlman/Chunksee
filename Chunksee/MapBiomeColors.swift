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
    private let colors: [String: Biome]

    init(world: World, assetSourceKey: String, definitions: [String: BiomeDefinition],
         colorMaps: [Identifier: ItemTexture]) {
        self.assetSourceKey = assetSourceKey
        dataVersion = world.level.dataVersion
        enabledPacks = world.level.enabledDataPacks
        colors = definitions.mapValues { Biome(definition: $0, colorMaps: colorMaps) }
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

    /// The renderer retains this lookup once per distinct saved biome string in a chunk.
    func biome(_ name: String) -> Biome {
        guard let id = Identifier(name) else { return .unavailable }
        return colors[id.description] ?? .unavailable
    }

    struct Biome: Sendable {
        static let unavailable = Biome(constants: [:], swamp: nil)
        private let constants: [BiomeColor: UInt32]
        private let swamp: BiomeDefinition?

        private init(constants: [BiomeColor: UInt32], swamp: BiomeDefinition?) {
            self.constants = constants
            self.swamp = swamp
        }

        fileprivate init(definition: BiomeDefinition, colorMaps: [Identifier: ItemTexture]) {
            // Kit documents swamp grass as its only position-dependent source. Resolve all
            // other sources once per world snapshot; Kit still owns every color calculation.
            let swamp = definition.grassColorModifier == .swamp ? definition : nil
            var constants: [BiomeColor: UInt32] = [:]
            for source in BiomeColor.allCases where source != .grass || swamp == nil {
                constants[source] = definition.color(source, x: 0, z: 0) { id, pixel in
                    guard let texture = colorMaps[id], texture.width == 256, texture.height == 256 else { return nil }
                    return texture.rgb(at: pixel)
                }
            }
            self.init(constants: constants, swamp: swamp)
        }

        func color(_ source: BiomeColor, x: Int32, z: Int32) -> UInt32? {
            if source == .grass, let swamp {
                return swamp.color(source, x: x, z: z) { _, _ in nil }
            }
            return constants[source]
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
    /// Keep the common zero/one-tint request inline instead of allocating per map column.
    struct Tints: Hashable, Sendable {
        private var first: Tint?
        private var remaining: [Tint] = []

        mutating func append(_ tint: Tint) {
            if first == nil { first = tint }
            else { remaining.append(tint) }
        }

        func color(at index: Int) -> UInt32? {
            if first?.index == index { return first?.color }
            return remaining.first { $0.index == index }?.color
        }

        var count: Int { (first == nil ? 0 : 1) + remaining.count }
    }
    let state: BlockState
    var tints = Tints()
}
