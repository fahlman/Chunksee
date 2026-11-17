import ChunkseeKit
import Foundation

/// Saved facts are independent of installed game definitions and artwork. The current World
/// carries their level.dat snapshot so presentation never combines a new version with old age,
/// difficulty, spawn or pack metadata.
nonisolated struct WorldInfoSnapshot: Sendable {
    var world: World
    var seed: Int64?
    var gameRules: [String: GameRuleValue] = [:]
    var weather: Weather?
    var dayTime: Int?
    var borders: [String: WorldBorder] = [:]
    var dragonFight: EnderDragonFight?
    var wanderingTrader: WanderingTraderTimer?

    /// Opening and refresh use the same field reads. A successful nil/empty value removes
    /// its fact; a thrown read preserves only that field from the same world's prior snapshot.
    static func read(_ world: World, dimensions: [ChunkseeKit.Dimension],
                     retaining previous: Self? = nil) -> RefreshRead<Self> {
        var next = (previous?.world.url == world.url ? previous : nil) ?? Self(world: world)
        next.world = world
        var failed = false
        func accept<Value>(_ field: WritableKeyPath<Self, Value>, _ read: () throws -> Value) {
            do { next[keyPath: field] = try read() }
            catch { failed = true }
        }
        accept(\.seed, world.seed)
        accept(\.gameRules, world.gameRules)
        accept(\.weather, world.weather)
        accept(\.dayTime, world.dayTime)
        accept(\.dragonFight, world.enderDragonFight)
        accept(\.wanderingTrader, world.wanderingTrader)
        let known = Set(dimensions.map(\.id))
        next.borders = next.borders.filter { known.contains($0.key) }
        for dimension in dimensions {
            do { next.borders[dimension.id] = try world.worldBorder(of: dimension) }
            catch { failed = true }
        }
        return failed ? .partial(next) : .complete(next)
    }

    @concurrent
    static func refreshed(_ world: World, dimensions: [ChunkseeKit.Dimension],
                          retaining previous: Self?) async throws -> RefreshRead<Self> {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        let result = read(current, dimensions: dimensions, retaining: previous)
        try Task.checkCancellation()
        return result
    }
}

/// Catalog changes replace a read's inputs; ordinary saves keep this source and coalesce.
nonisolated struct WorldInfoSource: Equatable, Sendable {
    let worldSource: WorldReadSource
    let dimensions: [ChunkseeKit.Dimension]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.worldSource == rhs.worldSource && lhs.dimensions.count == rhs.dimensions.count &&
            zip(lhs.dimensions, rhs.dimensions).allSatisfy { $0.0.id == $0.1.id && $0.0.url == $0.1.url }
    }
}
