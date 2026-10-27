import ChunkseeKit
import ChunkseeIndex

/// One world's interpretation context. The selected jar is shared, while enabled data-pack
/// overrides belong to this world. Readers retain this value for their entire operation.
nonisolated struct WorldDefinitions: Sendable, Equatable {
    var dimensionSettings: [String: DimensionSettings] = [:]
    var enchantments: [String: EnchantmentDefinition] = [:]
    var possibleBiomes: [String: [String]] = [:]
    var notableBlocks = NotableBlock.Catalog(tags: [:])
    var structureGroups = StructureGroup.Catalog(tags: [:])
    var placeGroups = PlaceGroup.Catalog(tags: [:])
    var trading: TradingDefinitions?

    static func read(_ world: World, assets: GameAssets?) throws -> Self {
        try Task.checkCancellation()
        var result = Self()
        // A damaged resource category cannot hide independently readable game facts.
        result.dimensionSettings = (try? world.dimensionSettings(assets: assets)) ?? [:]
        result.enchantments = (try? world.enchantmentDefinitions(assets: assets)) ?? [:]
        result.notableBlocks = NotableBlock.Catalog(tags: (try? world.tags(for: NotableBlock.tagIDs, in: "block", assets: assets)) ?? [:])
        result.structureGroups = StructureGroup.Catalog(tags: (try? world.tags(for: StructureGroup.tagIDs,
            in: "worldgen/structure", assets: assets)) ?? [:])
        result.placeGroups = PlaceGroup.Catalog(tags: (try? world.tags(for: PlaceGroup.tagIDs,
            in: "point_of_interest_type", assets: assets)) ?? [:])
        result.trading = try? world.tradingDefinitions(assets: assets)
        for dimension in world.dimensions() {
            result.possibleBiomes[dimension.id] = try? world.possibleBiomes(in: dimension.id, assets: assets)
        }
        try Task.checkCancellation()
        return result
    }
}
