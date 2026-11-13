import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@MainActor
final class TerrainComparisonWorld {
    final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    private var names: PlayerNames?
    private var resources: WorldResources?
    private var anchor: WorldSession?
    private let environment: TerrainComparisonWorkload.Environment
    private(set) var owners: [Weak] = []
    private(set) var viewOwners: [Weak] = []

    init(environment: TerrainComparisonWorkload.Environment) { self.environment = environment }

    /// One anchor keeps the product's world, readers and private disk cache alive. Each
    /// case gets a fresh view session, so no case retains another case's map images.
    func open(world: URL, game: URL, cache: URL) async throws {
        try #require(names == nil && resources == nil && anchor == nil)
        let defaults = TestDefaults.make()
        let names = PlayerNames(defaults: defaults)
        self.names = names
        owners += [Weak(names), Weak(names.minecraft)]
        try #require(!names.looksUpOnline)
        names.minecraft.choose(game)
        names.minecraft.usesGameArtwork = true
        let snapshot = try await WorldSnapshot.read(world)
        let prepared = try await WorldPreparation.read(snapshot, minecraft: names.minecraft)
        let resources = WorldResources(prepared: prepared, names: names,
            savedSearches: SavedSearches(defaults: defaults),
            settings: WorldSettings(id: UUID(uuidString: "B50EA150-DFE2-4228-ABFC-593220B0C565")!, defaults: defaults),
            cacheRoot: cache, watchWorld: { _, _ in nil })
        self.resources = resources
        let anchor = WorldSession(resources: resources, dimensionID: environment.dimension)
        self.anchor = anchor
        owners += [Weak(resources), Weak(resources.index), Weak(resources.queryStore), Weak(anchor)]
        owners += resources.readers.values.map { Weak($0) }
        resources.refreshGameLanguage(preferredLanguage: environment.locale)
        await Self.settle(anchor)
        try #require(resources.mapGameResources.data != nil && resources.mapGameResources.artwork != nil)
    }

    func close() async {
        anchor?.close()
        await anchor?.waitUntilClosed()
        resources?.close()
        await resources?.waitUntilClosed()
        anchor = nil
        resources = nil
        names?.minecraft.forget()
        await names?.minecraft.waitUntilIdle()
        names = nil
    }

    func view<T>(_ row: TerrainComparisonWorkload.ViewCase,
                 operation: @MainActor (WorldSession) async throws -> T) async throws -> T {
        try await session(settings: row.settings) { session in
            let map = try #require(session.map)
            map.viewport = row.viewport
            await Self.settle(session)
            map.requestTiles(visibleIn: self.environment.size, displayScale: self.environment.displayScale)
            await Self.settle(session)
            try #require(map.unfinishedCacheWrites == 0 && !map.isLoading)
            return try await operation(session)
        }
    }

    func export<T>(_ row: TerrainComparisonWorkload.ExportCase,
                   operation: @MainActor (WorldSession, MapExportPlan) async throws -> T) async throws -> T {
        try await session(settings: row.settings) { session in
            let plan = try row.plan()
            let map = try #require(session.map)
            map.viewport = plan.viewport
            await Self.settle(session)
            // Do not request view tiles here: export owns its streaming reads and cache writes.
            try #require(map.tiles.isEmpty && map.previews.isEmpty && map.detailImages.isEmpty)
            return try await operation(session, plan)
        }
    }

    private func session<T>(settings: TerrainComparisonWorkload.Settings,
                            operation: @MainActor (WorldSession) async throws -> T) async throws -> T {
        let resources = try #require(resources), names = try #require(names)
        names.minecraft.usesGameArtwork = settings.gameArtwork
        await resources.waitForRefresh()
        let session = WorldSession(resources: resources, dimensionID: environment.dimension)
        let viewOwners = [Weak(session), Weak(session.heatMap), Weak(session.slimeChunks)]
        self.viewOwners += viewOwners
        owners += viewOwners
        do {
            let map = try #require(session.map)
            owners.append(Weak(map))
            self.viewOwners.append(Weak(map))
            await Self.settle(session)
            session.selection.choose(nil)
            var layers = LayerVisibility()
            layers.structures = []
            layers.places = []
            layers.creatures = []
            layers.mobTypes = []
            layers.mobAppearances = [:]
            layers.biomes = []
            layers.hiddenPlayers = Set(session.players.map(\.uuid))
            layers.showsGrid = false
            layers.showsSavedPlaces = false
            layers.showsWorldBorder = false
            layers.showsDarkSpots = false
            layers.showsTimeSpent = settings.timeSpent
            layers.showsSlimeChunks = settings.slimeChunks
            session.visibility = layers
            try #require(settings.surface)
            map.setDepth(MapDepth())
            map.setStyle(settings.style)
            map.setLightingMode(settings.lightingMode)
            map.setCastsShadows(settings.castsShadows)
            map.setBiomeBlending(settings.blendsBiomeColors)
            map.setBlockFilter(MapBlockFilter())
            await Self.settle(session)
            try #require(map.style == settings.style)
            try #require((resources.mapGameResources.artwork != nil) == settings.gameArtwork)
            try #require(resources.mapGameResources.data != nil)
            let result = try await operation(session)
            session.close()
            await session.waitUntilClosed()
            return result
        } catch {
            session.close()
            await session.waitUntilClosed()
            throw error
        }
    }

    static func settle(_ session: WorldSession) async {
        await session.resources.waitForRefresh()
        await session.resources.backgroundWork.waitUntilFinished()
        await session.search.waitForIndex()
        await session.search.waitForSearch()
        await session.resources.index.waitForProjection()
        await session.heatMap.waitForReads()
        await session.slimeChunks.waitForImages()
        await session.map?.waitUntilIdle()
        await session.map?.waitForRenders()
        await session.map?.waitForTopBlocks()
    }
}
