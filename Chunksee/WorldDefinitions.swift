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

    /// Opening and refresh share the same source choice. The caller supplies its current
    /// dimension catalog so opening can reuse the folders it already enumerated.
    @concurrent
    static func read(_ world: World, dimensions: [ChunkseeKit.Dimension],
                     library: GameDataLibrary?, retaining previous: Self? = nil) async throws -> RefreshRead<Self> {
        try Task.checkCancellation()
        let definitions: RefreshRead<Self>
        if let library { definitions = try await library.definitions(in: world, dimensions: dimensions, retaining: previous) }
        else { definitions = try read(world, dimensions: dimensions, assets: nil, retaining: previous) }
        try Task.checkCancellation()
        return definitions
    }

    /// The loader supplies previous facts only from this same world and game source. A failed
    /// category keeps those facts; a successful nil or empty read authoritatively removes them.
    static func read(_ world: World, dimensions: [ChunkseeKit.Dimension], assets: GameAssets?,
                     retaining previous: Self? = nil) throws -> RefreshRead<Self> {
        try Task.checkCancellation()
        var result = previous ?? Self(), failed = false
        func accept(_ read: () throws -> Void) throws {
            try Task.checkCancellation()
            do { try read() }
            catch let error as CancellationError { throw error }
            catch { failed = true }
        }
        try accept { result.dimensionSettings = try world.dimensionSettings(assets: assets) }
        try accept { result.enchantments = try world.enchantmentDefinitions(assets: assets) }
        try accept {
            let tags = try world.tags(for: NotableBlock.tagIDs.union(["minecraft:leaves"]), in: "block", assets: assets)
            result.notableBlocks = NotableBlock.Catalog(tags: tags)
            result.leafTag = tags["minecraft:leaves"]
        }
        try accept {
            result.structureGroups = StructureGroup.Catalog(tags: try world.tags(for: StructureGroup.tagIDs,
                in: "worldgen/structure", assets: assets))
        }
        try accept { result.trading = try world.tradingDefinitions(assets: assets) }
        try accept { result.water = try world.tags(for: ["minecraft:water"], in: "fluid", assets: assets)["minecraft:water"] }
        let known = Set(dimensions.map(\.id))
        result.possibleBiomes = result.possibleBiomes.filter { known.contains($0.key) }
        for dimension in dimensions {
            try accept { result.possibleBiomes[dimension.id] = try world.possibleBiomes(in: dimension.id, assets: assets) }
        }
        try Task.checkCancellation()
        return failed ? .partial(result) : .complete(result)
    }
}
