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
    let seed: Int64?
    let sampler: BiomeSampler?
    private let colors: [String: Biome]

    init(world: World, assetSourceKey: String, definitions: [String: BiomeDefinition],
         colorMaps: [Identifier: ItemTexture]) throws {
        seed = try world.seed()
        sampler = world.level.dataVersion == SaveVersion.java26_3 ? seed.map(BiomeSampler.init(seed:)) : nil
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
        sourceKey = CacheKey.hash(assetSourceKey + "\nseed:" + (seed.map(String.init) ?? "unknown") + "\n" + rows.joined(separator: "\n"))
    }

    func matchesMetadata(_ world: World, assetSourceKey: String) throws -> Bool {
        guard self.assetSourceKey == assetSourceKey, dataVersion == world.level.dataVersion,
              enabledPacks == world.level.enabledDataPacks else { return false }
        return seed == (try world.seed())
    }

    /// The renderer retains this lookup once per distinct saved biome string in a chunk.
    func biome(_ name: String) -> Biome {
        guard let id = Identifier(name) else { return .unavailable }
        return colors[id.description] ?? .unavailable
    }

    struct Biome: Sendable {
        static let unavailable = Biome(grass: .constant(nil), foliage: .constant(nil),
                                       dryFoliage: .constant(nil), water: .constant(nil))
        private let grass: Color
        private let foliage: Color
        private let dryFoliage: Color
        private let water: Color

        func color(_ source: BiomeColor, x: Int32, z: Int32) -> UInt32? {
            let color: Color
            switch source {
            case .grass: color = grass
            case .foliage: color = foliage
            case .dryFoliage: color = dryFoliage
            case .water: color = water
            }
            switch color {
            case .constant(let rgb): return rgb
            case .positioned(let definition, let colorMaps):
                return Self.resolve(source, definition: definition, x: x, z: z, colorMaps: colorMaps)
            }
        }

        // Constant colors carry no shared storage to retain on every parallel column read.
        // Kit alone decides which sources need their definition and maps at a position.
        private enum Color: Sendable {
            case constant(UInt32?)
            case positioned(BiomeDefinition, [Identifier: ItemTexture])
        }

        private init(grass: Color, foliage: Color, dryFoliage: Color, water: Color) {
            self.grass = grass
            self.foliage = foliage
            self.dryFoliage = dryFoliage
            self.water = water
        }

        fileprivate init(definition: BiomeDefinition, colorMaps: [Identifier: ItemTexture]) {
            func prepare(_ source: BiomeColor) -> Color {
                if definition.colorDependsOnPosition(source) { return .positioned(definition, colorMaps) }
                return .constant(Self.resolve(source, definition: definition, x: 0, z: 0, colorMaps: colorMaps))
            }
            self.init(grass: prepare(.grass), foliage: prepare(.foliage),
                      dryFoliage: prepare(.dryFoliage), water: prepare(.water))
        }

        private static func resolve(_ source: BiomeColor, definition: BiomeDefinition, x: Int32, z: Int32,
                                    colorMaps: [Identifier: ItemTexture]) -> UInt32? {
            definition.color(source, x: x, z: z) { id, pixel in
                guard let texture = colorMaps[id], texture.width == 256, texture.height == 256 else { return nil }
                return texture.rgb(at: pixel)
            }
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
    struct Tint: Hashable, Sendable, Codable {
        let index: Int
        let color: UInt32
    }
    /// Keep the common zero/one-tint request inline instead of allocating per map column.
    struct Tints: Hashable, Sendable, Codable {
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

extension MapBlockColorRequest: Codable {
    private enum CodingKeys: String, CodingKey { case id, properties, tints }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = BlockState(try values.decode(String.self, forKey: .id),
                           properties: try values.decode([String: String].self, forKey: .properties))
        tints = try values.decode(Tints.self, forKey: .tints)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state.id, forKey: .id)
        try values.encode(state.properties, forKey: .properties)
        try values.encode(tints, forKey: .tints)
    }
}
