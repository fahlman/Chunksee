import Foundation
import ChunkseeKit
import Observation

/// A document snapshot owns its own opening, never another document's raw file-access token.
/// Finishing after attachment leaves the session as owner; dropping an unused snapshot can close
/// the world once its other openings and sessions are gone.
final class WorldOpening {
    private(set) var resources: WorldResources?
    private let id: UUID

    fileprivate init(resources: WorldResources, id: UUID) {
        self.resources = resources
        self.id = id
    }

    func finish() {
        guard let resources else { return }
        self.resources = nil
        resources.finishOpening(id)
    }

    isolated deinit { finish() }
}

/// One world's access and reads, shared by its open dimension documents, each of which owns only
/// its presentation. Closing the last of them closes the world.
@Observable
final class WorldResources {
    let access: WorldReadAccess
    let backgroundWork: BackgroundWork
    let world: World
    var dimensions: [ChunkseeKit.Dimension] { index.readers.map(\.dimension) }
    private(set) var dimensionDocuments: [String: String]
    private(set) var details: WorldDetails
    let names: PlayerNames
    let savedSearches: SavedSearches
    let savedPlaces: SavedPlaces
    var readers: [String: RegionReader] { Dictionary(uniqueKeysWithValues: index.readers.map { ($0.dimension.id, $0) }) }
    let index: WorldIndexStore
    let settings: WorldSettings
    let cacheRoot: URL?
    let playerRoster: PlayerRoster
    var playerSnapshot: PlayerSnapshot { playerRoster.snapshot }
    var players: [PlayerInfo] { playerSnapshot.players }
    private let readRegion: RegionReader.Read
    var activeDimensionID: String?
    private(set) var isClosed = false
    @ObservationIgnored private var sessions: [UUID: WeakSession] = [:]
    @ObservationIgnored private var openings: Set<UUID> = []
    /// Jumps waiting for a dimension's document to open.
    @ObservationIgnored private var pendingActions: [String: (id: UUID, action: (WorldSession) -> Void)] = [:]
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: WorldWatcher?
    @ObservationIgnored private var pendingIndex: [String: RegionChange] = [:]
    /// Entity/POI saves change the index without invalidating terrain images or inhabited times.
    @ObservationIgnored private var pendingTerrain: [String: RegionChange] = [:]
    @ObservationIgnored private var pendingPlayers = false
    @ObservationIgnored private var pendingLighting = false
    @ObservationIgnored private var pendingBiomeMetadata = false
    @ObservationIgnored private var pendingBiomePacks = false
    private let refreshWork: BackgroundWork.Scope
    private let biomeWork: BackgroundWork.Scope
    private let definitionsWork: BackgroundWork.Scope
    private let assetWork: BackgroundWork.Scope
    @ObservationIgnored private var assetObserver: UUID?
    @ObservationIgnored private var assetReadGeneration = 0
    @ObservationIgnored private var isAssetReadPending = false
    @ObservationIgnored private var definitionReadGeneration = 0
    @ObservationIgnored private var isDefinitionReadPending = false
    @ObservationIgnored var readDefinitions: @Sendable (World, GameAssetLibrary?) async throws -> DefinitionSnapshot = {
        try await WorldResources.readDefinitions($0, library: $1)
    }
    private let nightLightWork: BackgroundWork.Scope
    @ObservationIgnored private var nightLighting: [String: MonsterSpawnLight]?
    @ObservationIgnored private var nightReadGeneration = 0
    @ObservationIgnored private var needsNightReload = true
    @ObservationIgnored private var isNightReadPending = false
    @ObservationIgnored var readNightLighting: @Sendable (World, GameAssetLibrary?) async throws -> [String: MonsterSpawnLight] = {
        try await WorldResources.readNightLighting($0, library: $1)
    }
    private let lightingWork: BackgroundWork.Scope
    @ObservationIgnored private var lightingReadGeneration = 0
    @ObservationIgnored private var lighting: [String: MapLighting] = [:]
    @ObservationIgnored var readLighting: @Sendable (World, GameAssetLibrary?) async throws -> [String: MapLighting] = {
        try await WorldResources.readLighting($0, library: $1)
    }
    @ObservationIgnored private var gameAssetSource: WorldGameAssetSource?
    @ObservationIgnored private var gameAssets: GameAssetLibrary?
    @ObservationIgnored private var biomeColors: MapBiomeColors?
    @ObservationIgnored private var biomeReadGeneration = 0
    @ObservationIgnored private var needsBiomeReload = false
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)
    /// Tests can hold this boundary without making refresh correctness depend on scheduler speed.
    @ObservationIgnored var waitBeforeRefresh: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private var isRefreshScheduled = false
    @ObservationIgnored private var playerReadGeneration = 0
    /// Reads the world's player files off the main actor; tests substitute a controlled read.
    @ObservationIgnored var readPlayers: @Sendable (World, [String: EnchantmentDefinition]) async -> [PlayerInfo]? = { await WorldResources.readPlayers($0, enchantments: $1) }
    @ObservationIgnored var readBiomeColors: @Sendable (World, GameAssetLibrary, MapBiomeColors?, Bool) async throws -> MapBiomeColors = {
        try await WorldResources.readBiomeColors($0, library: $1, previous: $2, reload: $3)
    }

    private final class WeakSession {
        weak var value: WorldSession?
        init(_ value: WorldSession) { self.value = value }
    }

    var url: URL { access.url }
    var defaultDimensionID: String? {
        settings.lastDimension.flatMap { id in dimensions.first { $0.id == id }?.id } ?? dimensions.first?.id
    }

    /// Tests that inject file changes substitute the watcher so real notifications cannot race
    /// their controlled events. Documents use the normal FSEvents source and own its lifetime here.
    init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
         settings: WorldSettings, cacheRoot: URL?,
         watchWorld: @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = WorldWatcher.init,
         readRegion: @escaping RegionReader.Read = RegionReader.scan,
         maintainCache: @escaping @Sendable (URL, URL) async -> Void = WorldResources.maintainCache) {
        let backgroundWork = BackgroundWork()
        self.backgroundWork = backgroundWork
        refreshWork = backgroundWork.makeScope()
        biomeWork = backgroundWork.makeScope()
        definitionsWork = backgroundWork.makeScope()
        assetWork = backgroundWork.makeScope()
        nightLightWork = backgroundWork.makeScope()
        lightingWork = backgroundWork.makeScope()
        access = snapshot.access
        world = snapshot.world
        dimensionDocuments = snapshot.dimensionDocuments
        details = snapshot.details
        playerRoster = PlayerRoster(snapshot.players)
        self.names = names
        self.savedSearches = savedSearches
        self.cacheRoot = cacheRoot
        self.readRegion = readRegion
        self.settings = settings
        savedPlaces = SavedPlaces(settings: settings)
        let readers = snapshot.dimensions.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: snapshot.access.url, dimensionID: dimension.id, root: cacheRoot),
                         options: RegionReader.options(context: MapSurfaceContext(settings: snapshot.details.dimensionSettings[dimension.id]), definitions: snapshot.details.definitions),
                         notableBlocks: snapshot.details.definitions.notableBlocks,
                         structureGroups: snapshot.details.definitions.structureGroups,
                         read: readRegion)
        }
        let last = settings.lastDimension.flatMap { id in snapshot.dimensions.first { $0.id == id }?.id }
        let firstDimension = last ?? snapshot.dimensions.first?.id
        activeDimensionID = firstDimension
        index = WorldIndexStore(readers: readers, work: backgroundWork, firstDimension: firstDimension)
        watcher = watchWorld(snapshot.access.url) { [weak self] in self?.worldChanged($0) }
        assetObserver = names.minecraft.observeChanges { [weak self] in self?.refreshGameAssets() }
        refreshLighting()
        if let root = cacheRoot, let folder = TileCache.worldFolder(forWorldAt: snapshot.access.url, root: root) {
            backgroundWork.start(priority: .background) {
                await Self.runCacheMaintenance(maintainCache, root: root, folder: folder)
            }
        }
    }

    /// Fresh metadata extends the catalog without replacing readers or any attached tab's map.
    /// The snapshot's own access remains the caller's; this world keeps its original root access.
    func includeDimensions(from snapshot: WorldSnapshot) {
        guard !isClosed else { return }
        let known = Set(dimensions.map(\.id))
        let added = snapshot.dimensions.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        let newIDs = Set(added.map(\.id))
        for id in newIDs { details.definitions.dimensionSettings[id] = snapshot.details.dimensionSettings[id] }
        dimensionDocuments.merge(snapshot.dimensionDocuments.filter { newIDs.contains($0.value) }) { old, _ in old }
        index.include(added.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot),
                         options: RegionReader.options(context: MapSurfaceContext(settings: details.dimensionSettings[dimension.id]), definitions: details.definitions),
                         notableBlocks: details.definitions.notableBlocks,
                         structureGroups: details.definitions.structureGroups,
                         read: readRegion)
        }, firstDimension: activeDimensionID)
        refreshNightLighting()
        refreshLighting()
        refreshDefinitions()
    }

    @concurrent nonisolated static func maintainCache(root: URL, folder: URL) async {
        guard !Task.isCancelled else { return }
        TileCache.markUsed(worldFolder: folder)
        guard !Task.isCancelled else { return }
        TileCache.prune(root: root, limit: 1 << 30, keeping: folder)
    }

    /// The work registry is main-actor isolated; maintenance keeps its off-main I/O boundary.
    @concurrent private nonisolated static func runCacheMaintenance(
        _ operation: @Sendable (URL, URL) async -> Void, root: URL, folder: URL
    ) async {
        await operation(root, folder)
    }

    func attach(_ session: WorldSession) {
        sessions[session.viewID] = WeakSession(session)
        session.map?.setGameAssets(gameAssets, biomeColors: biomeColors)
        darkSpotsVisibilityChanged()
        session.map?.setSavedLighting(session.selectedDimensionID.flatMap { lighting[$0] })
        if let id = session.selectedDimensionID, let pending = pendingActions.removeValue(forKey: id) { pending.action(session) }
    }

    /// Multiple dimension views can observe the same source change. Retire it once for the
    /// world; opening another tab must not clear its siblings' color snapshot.
    func prepareGameAssets(_ source: WorldGameAssetSource) {
        guard !isClosed, source.generation == names.minecraft.generation, gameAssetSource != source else { return }
        gameAssetSource = source
        assetReadGeneration += 1
        assetWork.cancel()
        isAssetReadPending = false
        biomeReadGeneration += 1
        biomeWork.cancel()
        gameAssets = nil
        biomeColors = nil
        lighting = [:]
        for session in sessions.values.compactMap(\.value) {
            session.map?.setGameAssets(nil)
            session.map?.setSavedLighting(nil)
        }
        refreshLighting()
        clearNightLighting()
        refreshNightLighting()
        refreshDefinitions()
    }

    /// All dimension views share one source request. Permission changes also reach hidden tabs,
    /// whose SwiftUI tasks may not run until they become visible again.
    func refreshGameAssets() {
        guard !isClosed else { return }
        let source = WorldGameAssetSource(generation: names.minecraft.generation)
        prepareGameAssets(source)
        guard !isAssetReadPending else { return }
        let generation = assetReadGeneration, minecraft = names.minecraft
        isAssetReadPending = true
        assetWork.start(priority: .utility) { [weak self] in
            let library = await minecraft.library()
            guard !Task.isCancelled, let self, !self.isClosed,
                  self.assetReadGeneration == generation, minecraft.generation == source.generation else { return }
            self.isAssetReadPending = false
            self.setGameAssets(library, source: source)
        }
    }

    func setGameAssets(_ library: GameAssetLibrary?, source: WorldGameAssetSource) {
        guard !isClosed, source.generation == names.minecraft.generation,
              gameAssetSource == source, gameAssets?.identity != library?.identity else { return }
        biomeReadGeneration += 1
        biomeWork.cancel()
        gameAssets = library
        biomeColors = nil
        for session in sessions.values.compactMap(\.value) { session.map?.setGameAssets(nil) }
        refreshBiomeColors(reload: true)
        clearNightLighting()
        refreshNightLighting()
        refreshLighting()
        refreshDefinitions()
    }

    func gameAssetLibrary(for source: WorldGameAssetSource) -> GameAssetLibrary? {
        guard !isClosed, source == gameAssetSource, source.generation == names.minecraft.generation else { return nil }
        return gameAssets
    }

    nonisolated struct DefinitionSnapshot: Sendable {
        let definitions: WorldDefinitions
        let borders: [String: WorldBorder]
    }

    private func refreshDefinitions() {
        guard !isClosed else { return }
        definitionReadGeneration += 1
        playerReadGeneration += 1
        let generation = definitionReadGeneration, library = gameAssets, read = readDefinitions, world = world
        let readPlayers = readPlayers
        definitionsWork.cancel()
        isDefinitionReadPending = true
        definitionsWork.start(priority: .utility) { [weak self] in
            let updated = try? await read(world, library)
            guard !Task.isCancelled, let updated else {
                if self?.definitionReadGeneration == generation { self?.isDefinitionReadPending = false }
                return
            }
            let players = await readPlayers(world, updated.definitions.enchantments)
            guard !Task.isCancelled, let self, !self.isClosed,
                  self.definitionReadGeneration == generation,
                  self.gameAssets?.identity == library?.identity else { return }
            self.isDefinitionReadPending = false
            // Keep the last coherent snapshot during a transient unreadable save. Never pair
            // new region definitions with players whose maximum used the previous definitions.
            guard let players else { return }
            let previous = self.details.definitions
            self.details.definitions = updated.definitions
            self.details.borders = updated.borders
            self.playerRoster.publish(players)
            guard previous != updated.definitions else { return }
            let retired = self.index.readers
            let readers = retired.map { reader in
                let dimension = reader.dimension
                return RegionReader(dimension: dimension,
                    cache: ScanCache(forWorldAt: self.url, dimensionID: dimension.id, root: self.cacheRoot),
                    options: RegionReader.options(context: MapSurfaceContext(settings: updated.definitions.dimensionSettings[dimension.id]), definitions: updated.definitions),
                    notableBlocks: updated.definitions.notableBlocks,
                    structureGroups: updated.definitions.structureGroups, read: self.readRegion)
            }
            self.index.replace(readers: readers, firstDimension: self.activeDimensionID)
            for session in self.sessions.values.compactMap(\.value) {
                guard let id = session.selectedDimensionID else { continue }
                session.map?.setDimensionSettings(updated.definitions.dimensionSettings[id], water: updated.definitions.water)
                session.heatMap.replaceReader(self.readers[id])
            }
            self.backgroundWork.start(priority: .utility) {
                for reader in retired { await reader.close() }
            }
        }
    }

    @concurrent nonisolated static func readDefinitions(_ world: World, library: GameAssetLibrary?) async throws -> DefinitionSnapshot {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        let definitions: WorldDefinitions
        if let library { definitions = try await library.definitions(in: current) }
        else { definitions = try WorldDefinitions.read(current, assets: nil) }
        var borders: [String: WorldBorder] = [:]
        for dimension in current.dimensions() { borders[dimension.id] = try? current.worldBorder(of: dimension) }
        try Task.checkCancellation()
        return DefinitionSnapshot(definitions: definitions, borders: borders)
    }

    private func refreshBiomeColors(reload: Bool) {
        guard !isClosed, let library = gameAssets else { return }
        needsBiomeReload = needsBiomeReload || reload
        biomeReadGeneration += 1
        let generation = biomeReadGeneration
        biomeWork.cancel()
        let read = readBiomeColors, world = world, previous = biomeColors
        let reload = needsBiomeReload
        biomeWork.start(priority: nil) { [weak self] in
            let updated = try? await read(world, library, previous, reload)
            guard !Task.isCancelled, let self, !self.isClosed,
                  self.biomeReadGeneration == generation, self.gameAssets?.identity == library.identity else { return }
            // A transient unreadable save keeps its last good colors. A successful empty
            // catalog replaces them, so a removed or invalid pack cannot leave stale tints.
            if let updated { self.biomeColors = updated; self.needsBiomeReload = false }
            for session in self.sessions.values.compactMap(\.value) {
                session.map?.setGameAssets(library, biomeColors: self.biomeColors)
            }
        }
    }

    @concurrent nonisolated static func readBiomeColors(_ world: World, library: GameAssetLibrary,
                                                       previous: MapBiomeColors?, reload: Bool) async throws -> MapBiomeColors {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        if !reload, let previous, try previous.matchesMetadata(current, assetSourceKey: library.sourceKey) { return previous }
        return try await library.biomeColors(in: current)
    }

    /// Optional gameplay light metadata is shared by all interested dimension tabs. Ordinary
    /// windows do not start this read, and hiding the last layer cancels its current request.
    func darkSpotsVisibilityChanged() {
        guard !isClosed else { return }
        let documents = sessions.values.compactMap(\.value)
        guard documents.contains(where: { $0.map?.showsDarkSpots == true }) else {
            nightReadGeneration += 1
            nightLightWork.cancel()
            isNightReadPending = false
            return
        }
        for session in documents {
            session.map?.setNightLighting(session.selectedDimensionID.flatMap { nightLighting?[$0] })
        }
        if needsNightReload, !isNightReadPending { refreshNightLighting() }
    }

    private func clearNightLighting() {
        nightReadGeneration += 1
        nightLightWork.cancel()
        isNightReadPending = false
        nightLighting = nil
        needsNightReload = true
        for session in sessions.values.compactMap(\.value) { session.map?.setNightLighting(nil) }
    }

    private func refreshNightLighting() {
        needsNightReload = true
        guard !isClosed, sessions.values.contains(where: { $0.value?.map?.showsDarkSpots == true }) else { return }
        nightReadGeneration += 1
        let generation = nightReadGeneration, library = gameAssets, read = readNightLighting, world = world
        nightLightWork.cancel()
        isNightReadPending = true
        nightLightWork.start(priority: nil) { [weak self] in
            let updated = try? await read(world, library)
            guard !Task.isCancelled, let self, !self.isClosed, self.nightReadGeneration == generation,
                  self.gameAssets?.identity == library?.identity else { return }
            self.isNightReadPending = false
            // Keep the last good value after a transient read error. A successful empty
            // projection clears removed/unsupported rules, including those from data packs.
            guard let updated else { return }
            self.nightLighting = updated
            self.needsNightReload = false
            for session in self.sessions.values.compactMap(\.value) {
                session.map?.setNightLighting(session.selectedDimensionID.flatMap { updated[$0] })
            }
        }
    }

    private func refreshLighting() {
        guard !isClosed else { return }
        lightingReadGeneration += 1
        let generation = lightingReadGeneration, library = gameAssets, read = readLighting, world = world
        lightingWork.cancel()
        lightingWork.start(priority: nil) { [weak self] in
            let updated = try? await read(world, library)
            guard !Task.isCancelled, let self, !self.isClosed, generation == self.lightingReadGeneration,
                  self.gameAssets?.identity == library?.identity, let updated else { return }
            // A failed metadata read retains the last good clock. Successful unavailable data
            // clears it, so deleted packs or definitions cannot leave stale lighting behind.
            self.lighting = updated
            for session in self.sessions.values.compactMap(\.value) {
                session.map?.setSavedLighting(session.selectedDimensionID.flatMap { updated[$0] })
            }
        }
    }

    @concurrent nonisolated static func readNightLighting(_ world: World, library: GameAssetLibrary?) async throws -> [String: MonsterSpawnLight] {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        if let library { return try await library.nightLighting(in: current) }
        return try current.nightMonsterLighting(assets: nil)
    }

    @concurrent nonisolated static func readLighting(_ world: World, library: GameAssetLibrary?) async throws -> [String: MapLighting] {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        if let library { return try await library.lighting(in: current) }
        return try MapLighting.read(in: current, assets: nil)
    }

    func saveViews() {
        guard !isClosed else { return }
        for session in sessions.values { session.value?.saveView() }
    }

    /// Saving a place reveals its layer without opening or activating its dimension document.
    func showSavedPlaces(in dimension: String) {
        guard !isClosed else { return }
        let documents = sessions.values.compactMap(\.value).filter { !$0.isClosed && $0.selectedDimensionID == dimension }
        if documents.isEmpty {
            LayerVisibility(settings: settings, dimension: dimension).showsSavedPlaces = true
        } else {
            for document in documents { document.visibility.showsSavedPlaces = true }
        }
    }

    /// An initial document read keeps this world's access until it attaches a view or is dropped.
    func opening() throws -> WorldOpening {
        guard !isClosed else { throw CancellationError() }
        let id = UUID()
        openings.insert(id)
        return WorldOpening(resources: self, id: id)
    }

    fileprivate func finishOpening(_ id: UUID) {
        guard openings.remove(id) != nil else { return }
        closeIfUnused()
    }

    private func closeIfUnused() {
        if openings.isEmpty && sessions.values.allSatisfy({ $0.value == nil }) { close() }
    }

    /// Performs a jump in a dimension's view now if it's open, or else once its document opens.
    /// Only the latest waits, so a dimension that failed to open doesn't replay old jumps later.
    /// Returns the waiting request's ID, or `nil` when it already ran.
    @discardableResult
    func whenShowing(_ dimension: String, perform action: @escaping (WorldSession) -> Void) -> UUID? {
        if let session = sessions.values.compactMap(\.value).first(where: { !$0.isClosed && $0.selectedDimensionID == dimension }) {
            action(session)
            return nil
        }
        let id = UUID()
        pendingActions[dimension] = (id, action)
        return id
    }

    /// Drops a waiting jump whose dimension failed to open, unless a newer one replaced it.
    func cancelPending(_ request: UUID, in dimension: String) {
        if pendingActions[dimension]?.id == request { pendingActions[dimension] = nil }
    }

    func documentURL(for dimension: String) -> URL? {
        dimensions.first { $0.id == dimension }?.documentURL(inWorldAt: url)
    }

    func detach(_ session: WorldSession) {
        sessions[session.viewID] = nil
        darkSpotsVisibilityChanged()
        closeIfUnused()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let assetObserver { names.minecraft.stopObserving(assetObserver) }
        assetObserver = nil
        openings = []
        pendingActions = [:]
        watcher?.stop()
        backgroundWork.close()
        index.cancel()
        for session in sessions.values.compactMap(\.value) { session.close() }
        gameAssets = nil
        biomeColors = nil
        nightLighting = nil
        lighting = [:]
        let readers = Array(readers.values), index = index
        let access = access
        let backgroundWork = backgroundWork
        closingTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for reader in readers { group.addTask { await reader.close() } }
            }
            await index.waitForTasks()
            await backgroundWork.waitUntilFinished()
            access.release()
        }
    }

    func waitUntilClosed() async { await closingTask?.value }

    func worldChanged(_ files: [URL]) {
        guard !isClosed, !refreshWork.isClosed else { return }
        for file in files.map(\.standardizedFileURL) {
            let path = file.path
            if path == url.standardizedFileURL.path {
                // A broad notification can cover several dimension folders under this world.
                for dimension in dimensions {
                    pendingIndex[dimension.id] = .all
                    pendingTerrain[dimension.id] = .all
                }
                pendingPlayers = true
                pendingLighting = true
                pendingBiomeMetadata = true
                pendingBiomePacks = true
            } else if path == url.appendingPathComponent("level.dat").standardizedFileURL.path {
                pendingPlayers = true
                pendingLighting = true
                pendingBiomeMetadata = true
            } else if ["data", "data/minecraft", "data/world_gen_settings.dat", "data/minecraft/world_gen_settings.dat"]
                .contains(where: { path == url.appendingPathComponent($0).standardizedFileURL.path }) {
                pendingBiomeMetadata = true
                pendingLighting = true
            } else if ["data/world_clocks.dat", "data/minecraft/world_clocks.dat"]
                .contains(where: { path == url.appendingPathComponent($0).standardizedFileURL.path }) {
                pendingLighting = true
            } else if path == url.appendingPathComponent("datapacks").standardizedFileURL.path ||
                        path.hasPrefix(url.appendingPathComponent("datapacks").standardizedFileURL.path + "/") {
                pendingBiomePacks = true
                pendingLighting = true
            } else if path == world.playerDataDirectory.standardizedFileURL.path || path.hasPrefix(world.playerDataDirectory.standardizedFileURL.path + "/") {
                pendingPlayers = true
            } else if let dimension = dimensions.filter({ path == $0.url.standardizedFileURL.path || path.hasPrefix($0.url.standardizedFileURL.path + "/") })
                .max(by: { $0.url.path.count < $1.url.path.count }) {
                // Nether, End and custom dimension folders can sit inside the Overworld folder.
                let parent = file.deletingLastPathComponent().path
                if ChunkseeKit.Dimension.Folder.allCases.contains(where: { parent == dimension.directory($0).standardizedFileURL.path }),
                   let parsed = RegionFile.parseCoordinates(file.lastPathComponent) {
                    let change = RegionChange.regions([RegionPosition(x: parsed.x, z: parsed.z)])
                    if pendingIndex[dimension.id] != nil { pendingIndex[dimension.id]?.merge(change) }
                    else { pendingIndex[dimension.id] = change }
                    if parent == dimension.regionDirectory.standardizedFileURL.path {
                        if pendingTerrain[dimension.id] != nil { pendingTerrain[dimension.id]?.merge(change) }
                        else { pendingTerrain[dimension.id] = change }
                    }
                } else if path == dimension.url.standardizedFileURL.path ||
                            ChunkseeKit.Dimension.Folder.allCases.contains(where: { path == dimension.directory($0).standardizedFileURL.path }) {
                    // Only broad region/dimension events need reconciliation. Saved data such as
                    // raids.dat and chunk_tickets.dat does not feed the index, terrain or heat map.
                    pendingIndex[dimension.id] = .all
                    pendingTerrain[dimension.id] = .all
                }
            }
        }
        guard !pendingIndex.isEmpty || pendingPlayers || pendingBiomeMetadata || pendingBiomePacks || pendingLighting else { return }
        // While a player explores, the game saves region files every second or so. Changes join
        // the refresh already scheduled rather than postponing it, so the map catches up every
        // `refreshDelay` during play instead of only once the game goes quiet.
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        let delay = refreshDelay
        let wait = waitBeforeRefresh
        refreshWork.start(priority: nil) { [weak self] in
            try? await wait(delay)
            guard !Task.isCancelled, let self else { return }
            // Changes from here on schedule the next refresh.
            self.isRefreshScheduled = false
            await self.refresh()
        }
    }

    /// Waits for every refresh under way, including one still reading players behind a newer one.
    func waitForRefresh() async {
        await backgroundWork.waitUntilFinished(in: [refreshWork, biomeWork, nightLightWork, lightingWork, definitionsWork, assetWork])
    }

    private func refresh() async {
        let changed = pendingIndex, terrain = pendingTerrain, playersChanged = pendingPlayers
        let biomesChanged = pendingBiomeMetadata || pendingBiomePacks, reloadBiomes = pendingBiomePacks
        let lightingChanged = pendingLighting
        pendingLighting = false
        pendingIndex = [:]; pendingTerrain = [:]; pendingPlayers = false
        pendingBiomeMetadata = false; pendingBiomePacks = false
        for session in sessions.values.compactMap(\.value) {
            if let id = session.selectedDimensionID, let changes = terrain[id] {
                session.map?.regionsChanged(changes.mapRegions)
                session.heatMap.load(reread: true)
                session.slimeChunks.regionsChanged(session.map?.availableRegions ?? [])
            }
        }
        if !changed.isEmpty { index.rebuild(firstDimension: activeDimensionID, changes: changed) }
        if biomesChanged {
            refreshBiomeColors(reload: reloadBiomes)
            refreshNightLighting()
        }
        if lightingChanged { refreshLighting() }
        if biomesChanged || (playersChanged && isDefinitionReadPending) {
            refreshDefinitions()
        } else if playersChanged {
            // Refreshes can overlap while one reads players, so only the newest read is published:
            // an older, slower read finishing later must not put old positions back.
            playerReadGeneration += 1
            let generation = playerReadGeneration
            let updated = await readPlayers(world, details.definitions.enchantments)
            guard !Task.isCancelled, !isClosed, generation == playerReadGeneration, let updated else { return }
            playerRoster.publish(updated)
        }
    }

    @concurrent nonisolated static func readPlayers(_ world: World, enchantments: [String: EnchantmentDefinition]) async -> [PlayerInfo]? {
        // World keeps its opening level.dat snapshot, including the single-player fallback.
        // Reopen through Kit so a save updates that record too. An unreadable save must not
        // clear the last good players; a successful read with no players does clear them.
        guard !Task.isCancelled, let current = try? World(contentsOf: world.url) else { return nil }
        return current.players(enchantments: enchantments)
    }
}
