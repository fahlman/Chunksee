import ChunkseeKit
import ChunkseeIndex

/// One world's interpretation context. The selected jar is shared, while enabled data-pack
/// overrides belong to this world. Readers retain this value for their entire operation.
nonisolated struct WorldDefinitions: Sendable, Equatable {
    var dimensionSettings: [String: DimensionSettings] = [:]
    var enchantments: [String: EnchantmentDefinition] = [:]
    var possibleBiomes: [String: [String]] = [:]
    var notableBlocks = NotableBlock.Catalog(tags: [:])
    var leafTag: GameTag?
    var structureGroups = StructureGroup.Catalog(tags: [:])
    var trading: TradingDefinitions?
    var water: GameTag?

    static func read(_ world: World, assets: GameAssets?) throws -> Self {
        try Task.checkCancellation()
        return try read(world, dimensions: world.dimensions(), assets: assets)
    }

    /// Opening already enumerated the saved dimension folders. Refreshes use the entry point
    /// above to discover the current catalog instead of reusing an older opening list.
    static func read(_ world: World, dimensions: [ChunkseeKit.Dimension], assets: GameAssets?) throws -> Self {
        try Task.checkCancellation()
        var result = Self()
        // A damaged resource category cannot hide independently readable game facts.
        result.dimensionSettings = (try? world.dimensionSettings(assets: assets)) ?? [:]
        result.enchantments = (try? world.enchantmentDefinitions(assets: assets)) ?? [:]
        let blockTags = (try? world.tags(for: NotableBlock.tagIDs.union(["minecraft:leaves"]), in: "block", assets: assets)) ?? [:]
        result.notableBlocks = NotableBlock.Catalog(tags: blockTags)
        result.leafTag = blockTags["minecraft:leaves"]
        result.structureGroups = StructureGroup.Catalog(tags: (try? world.tags(for: StructureGroup.tagIDs,
            in: "worldgen/structure", assets: assets)) ?? [:])
        result.trading = try? world.tradingDefinitions(assets: assets)
        result.water = (try? world.tags(for: ["minecraft:water"], in: "fluid", assets: assets))?["minecraft:water"]
        for dimension in dimensions {
            result.possibleBiomes[dimension.id] = try? world.possibleBiomes(in: dimension.id, assets: assets)
        }
        try Task.checkCancellation()
        return result
    }
}
