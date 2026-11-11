import ChunkseeKit
import Foundation

nonisolated struct WorldGameAssetSource: Equatable, Sendable {
    let generation: UUID
}

/// Immutable color facts for one world and game archive. Dimension tabs share this value;
/// different enabled data packs never become mutable state in the shared archive reader.
nonisolated struct MapBiomeColors: Sendable {
    struct Key: Hashable, Sendable, Encodable {
        var interpretation = GameAssets.interpretationVersion
        let source: GameResourceSource
        let catalog: String
        let colorMaps: String?
    }

    private struct Catalog: Encodable {
        let seed: Int64?
        let definitions: [String: BiomeDefinition]
    }

    let sourceKey: Key
    var source: GameResourceSource { sourceKey.source }
    let dataVersion: Int?
    let enabledPacks: [String]
    let seed: Int64?
    let sampler: BiomeSampler?
    private let colors: [String: Biome]
    private let definitions: [String: BiomeDefinition]
    private let waterBiomes: Set<String>

    static func read(in world: World, source: GameResourceSource, assets: GameAssets?,
                     colorMaps: [Identifier: ItemTexture] = [:]) throws -> Self {
        let definitions = try world.biomeDefinitions(assets: assets)
        let tags = (try? world.tags(for: ["minecraft:is_ocean", "minecraft:is_river"],
                                   in: "worldgen/biome", assets: assets)) ?? [:]
        try Task.checkCancellation()
        return try Self(world: world, source: source, definitions: definitions,
                        colorMaps: colorMaps, waterBiomes: Set(tags.values.flatMap { $0.members.map(\.id) }))
    }

    init(world: World, source: GameResourceSource, definitions: [String: BiomeDefinition],
         colorMaps: [Identifier: ItemTexture], waterBiomes: Set<String> = []) throws {
        let seed = try world.seed()
        // Keep Kit's complete definitions in the identity. Compute this once at publication,
        // rather than enumerating its current fields or encoding the catalog for every tile.
        let catalog = try InterpretationKey.identity(of: Catalog(seed: seed, definitions: definitions))
        let maps = Dictionary(uniqueKeysWithValues: colorMaps.map { ($0.key.description, $0.value) })
        let pictures = maps.isEmpty ? nil : try InterpretationKey.identity(of: maps)
        self.init(source: source, catalog: catalog, pictures: pictures, seed: seed, dataVersion: world.level.dataVersion,
                  enabledPacks: world.level.enabledDataPacks, definitions: definitions,
                  colorMaps: colorMaps, waterBiomes: waterBiomes)
    }

    private init(source: GameResourceSource, catalog: String, pictures: String?, seed: Int64?, dataVersion: Int?, enabledPacks: [String],
                 definitions: [String: BiomeDefinition], colorMaps: [Identifier: ItemTexture], waterBiomes: Set<String>) {
        self.seed = seed
        sampler = seed.map(BiomeSampler.init(seed:))
        sourceKey = Key(source: source, catalog: catalog, colorMaps: pictures)
        self.waterBiomes = waterBiomes
        self.dataVersion = dataVersion
        self.enabledPacks = enabledPacks
        self.definitions = definitions
        colors = definitions.mapValues { Biome(definition: $0, colorMaps: colorMaps) }
    }

    /// Retain data immediately when a toggle retires artwork; no archive or image read is needed.
    func removingArtwork() -> Self {
        Self(source: .init(data: source.data, artwork: .unavailable), catalog: sourceKey.catalog, pictures: nil,
             seed: seed, dataVersion: dataVersion,
             enabledPacks: enabledPacks, definitions: definitions, colorMaps: [:], waterBiomes: waterBiomes)
    }

    /// Numeric definitions remain useful while artwork colors load. Available artwork colors
    /// belong only to their matching source; neither form may cross a game-data replacement.
    func available(for source: GameResourceSource) -> Self? {
        guard self.source.data == source.data,
              self.source.artwork == .unavailable || self.source.artwork == source.artwork else { return nil }
        return self
    }

    /// A map area uses one representative color, sampled at its saved representative point.
    /// Water tags affect the live outline only, never the cached terrain color source key.
    func outlineColor(for name: String, at position: CGPoint) -> MapColor? {
        guard let id = Identifier(name)?.description, let biome = colors[id],
              let point = MapCoordinates(point: position) else { return nil }
        let rgb: UInt32?
        if waterBiomes.contains(id) { rgb = biome.color(.water, x: point.x, z: point.z) }
        else {
            // Explicit overrides still work without artwork. If both land colormaps are
            // unavailable, use this definition's known water color before inventing a hash.
            rgb = biome.color(.grass, x: point.x, z: point.z)
                ?? biome.color(.foliage, x: point.x, z: point.z)
                ?? biome.color(.water, x: point.x, z: point.z)
        }
        return rgb.map(MapColor.init)
    }

    func matchesMetadata(_ world: World, source: GameResourceSource) throws -> Bool {
        guard self.source == source, dataVersion == world.level.dataVersion,
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
    let modelIsMissing: Bool
    let biomeTints: [BiomeTint]

    init(state: BlockState, model: AssetBlock?, modelIsMissing: Bool = false) {
        self.state = state
        self.model = model
        self.modelIsMissing = modelIsMissing
        let indices = Set(model?.parts.flatMap { part in
            part.alternatives.flatMap { alternative -> [Int] in
                switch alternative.model.geometry {
                case .elements(let elements): elements.flatMap { $0.faces.values.compactMap(\.tintIndex) }
                case .layers(let layers): layers.map(\.tintIndex)
                }
            }
        } ?? [])
        biomeTints = indices.sorted().compactMap { index in
            guard case .biome(let source, let offset) = state.tintSource(at: index) else { return nil }
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
