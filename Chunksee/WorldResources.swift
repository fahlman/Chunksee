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
    private(set) var savedVersion: SavedMinecraftVersion
    private var visibleNewerWorldNoticeID: String?
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
    private let definitionsWork: BackgroundWork.Scope
    private let assetWork: BackgroundWork.Scope
    private var languagePreference = GameLanguageChoice.preferredLanguage
    @ObservationIgnored private lazy var languageLoader = RefreshLoader<LanguageSource, RefreshInvalidation, GameNames>(
        work: backgroundWork, priority: .utility, whenInactive: .finish, source: languageSource
    ) { [weak self] source, previous in
        guard let library = source.library else { return .unavailable }
        guard let read = await self?.readLanguage else { throw CancellationError() }
        let language = await read(library, source.preference, source.folder)
        if let previous, previous.hasSameContents(as: language) { return previous }
        return GameNames(language)
    }
    @ObservationIgnored var readLanguage: @Sendable (GameDataLibrary, String, URL?) async -> GameLanguage? = {
        await $0.language($1, minecraftDirectory: $2)
    }

    nonisolated private struct LanguageSource: Equatable, Sendable {
        let generation: UUID
        let library: GameDataLibrary?
        let preference: String
        let folder: URL?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.generation == rhs.generation && lhs.library === rhs.library &&
                lhs.preference == rhs.preference && lhs.folder == rhs.folder
        }
    }
    private var languageSource: LanguageSource {
        LanguageSource(generation: names.minecraft.generation, library: gameData,
                       preference: languagePreference, folder: names.minecraft.folder)
    }
    @ObservationIgnored private var assetObserver: UUID?
    @ObservationIgnored private var assetReadGeneration = 0
    @ObservationIgnored private var isAssetReadPending = false
    private(set) var definitionReadGeneration = 0
    @ObservationIgnored private var isDefinitionReadPending = false
    @ObservationIgnored var readDefinitions: @Sendable (World, GameDataLibrary?) async throws -> DefinitionSnapshot = {
        try await WorldResources.readDefinitions($0, library: $1)
    }
    @ObservationIgnored var readPlayerRecords: @Sendable (World, UUID, String?, GameDataLibrary?) async -> PlayerRecords = {
        await PlayerRecords.load(from: $0, uuid: $1, name: $2, library: $3)
    }
    @ObservationIgnored private lazy var nightLightingLoader = RefreshLoader(
        work: backgroundWork, priority: nil, whenInactive: .cancel,
        source: LightingSource(generation: names.minecraft.generation, library: gameData)
    ) { [weak self, world] source, _ in
        guard let read = await self?.readNightLighting else { throw CancellationError() }
        return try await read(world, source.library)
    }
    @ObservationIgnored var readNightLighting: @Sendable (World, GameDataLibrary?) async throws -> [String: MonsterSpawnLight] = {
        try await WorldResources.readNightLighting($0, library: $1)
    }
    nonisolated private struct LightingSource: Equatable, Sendable {
        let generation: UUID
        let library: GameDataLibrary?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.generation == rhs.generation && lhs.library === rhs.library
        }
    }
    @ObservationIgnored private lazy var lightingLoader = RefreshLoader(
        work: backgroundWork, priority: nil, whenInactive: .finish,
        source: LightingSource(generation: names.minecraft.generation, library: gameData)
    ) { [weak self, world] source, _ in
        guard let read = await self?.readLighting else { throw CancellationError() }
        return try await read(world, source.library)
    }
    @ObservationIgnored var readLighting: @Sendable (World, GameDataLibrary?) async throws -> [String: MapLighting] = {
        try await WorldResources.readLighting($0, library: $1)
    }
    // The view accessor must observe both its initial source guard and the later loaded library.
    private var gameAssetSource: WorldGameAssetSource?
    private var gameAssets: GameResourceLibrary?
    private var gameData: GameDataLibrary? { gameAssets?.data }
    private var gameArtwork: GameArtworkLibrary? { names.minecraft.artwork(for: gameAssets) }
    var mapGameResources: MapGameResources {
        guard !isClosed, gameAssetSource?.generation == names.minecraft.generation else { return .unavailable }
        return MapGameResources(data: gameData, artwork: gameArtwork, biomeColors: biomeColors)
    }
    var biomeColors: MapBiomeColors? {
        guard !isClosed, biomeLoader.source == biomeSource else { return nil }
        return biomeLoader.value
    }
    @ObservationIgnored private lazy var biomeLoader = RefreshLoader<BiomeSource, BiomeRequest, MapBiomeColors>(
        work: backgroundWork, priority: nil, whenInactive: .finish, source: biomeSource,
        firstRequest: .metadata, merge: { $0.merging($1) }, retainingValue: { value, previous, current in
            guard previous.generation == current.generation, previous.data === current.data else { return nil }
            return value.removingArtwork()
        }
    ) { [weak self, world] source, request, previous in
        guard let read = await self?.readBiomeColors else { throw CancellationError() }
        return try await read(world, source.data, source.artwork, previous, request == .contents)
    }
    nonisolated private enum BiomeRequest: Equatable, Sendable {
        case metadata, contents
        func merging(_ other: Self) -> Self { self == .contents || other == .contents ? .contents : .metadata }
    }
    nonisolated private struct BiomeSource: Equatable, Sendable {
        let generation: UUID
        let data: GameDataLibrary?
        let artwork: GameArtworkLibrary?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.generation == rhs.generation && lhs.data === rhs.data && lhs.artwork === rhs.artwork
        }
    }
    private var biomeSource: BiomeSource {
        BiomeSource(generation: names.minecraft.generation, data: gameData, artwork: gameArtwork)
    }
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)
    /// Tests can hold this boundary without making refresh correctness depend on scheduler speed.
    @ObservationIgnored var waitBeforeRefresh: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private var isRefreshScheduled = false
    @ObservationIgnored private var playerReadGeneration = 0
    /// Reads the world's player files off the main actor; tests substitute a controlled read.
    @ObservationIgnored var readPlayers: @Sendable (World, [String: EnchantmentDefinition]) async -> [PlayerInfo]? = { await WorldResources.readPlayers($0, enchantments: $1) }
    @ObservationIgnored var readHeadingBlock: @Sendable (ChunkseeKit.Dimension, BlockPosition) async throws -> BlockState? = {
        try await WorldResources.readBlock($0, at: $1)
    }
    @ObservationIgnored var readBiomeColors: @Sendable (World, GameDataLibrary?, GameArtworkLibrary?, MapBiomeColors?, Bool) async throws -> MapBiomeColors = {
        try await WorldResources.readBiomeColors($0, data: $1, artwork: $2, previous: $3, reload: $4)
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
    init(prepared: WorldPreparation, names: PlayerNames, savedSearches: SavedSearches,
         settings: WorldSettings, cacheRoot: URL?,
         watchWorld: @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = WorldWatcher.init,
         readRegion: @escaping RegionReader.Read = RegionReader.scan,
         maintainCache: @escaping @Sendable (URL, URL) async -> Void = WorldResources.maintainCache) {
        let snapshot = prepared.snapshot
        let backgroundWork = BackgroundWork()
        self.backgroundWork = backgroundWork
        refreshWork = backgroundWork.makeScope()
        definitionsWork = backgroundWork.makeScope()
        assetWork = backgroundWork.makeScope()
        access = snapshot.access
        world = snapshot.world
        savedVersion = SavedMinecraftVersion(snapshot.world.level)
        dimensionDocuments = snapshot.dimensionDocuments
        details = snapshot.details
        playerRoster = PlayerRoster(snapshot.players)
        self.names = names
        gameAssetSource = prepared.source
        gameAssets = prepared.library
        self.savedSearches = savedSearches
        self.cacheRoot = cacheRoot
        self.readRegion = readRegion
        self.settings = settings
        savedPlaces = SavedPlaces(settings: settings)
        let readers = snapshot.dimensions.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: snapshot.access.url, dimensionID: dimension.id, root: cacheRoot),
                         options: RegionReader.options(context: MapSurfaceContext(settings: snapshot.details.dimensionSettings[dimension.id], water: snapshot.details.definitions.water), definitions: snapshot.details.definitions),
                         notableBlocks: snapshot.details.definitions.notableBlocks,
                         structureGroups: snapshot.details.definitions.structureGroups,
                         read: readRegion)
        }
        let last = settings.lastDimension.flatMap { id in snapshot.dimensions.first { $0.id == id }?.id }
        let firstDimension = last ?? snapshot.dimensions.first?.id
        activeDimensionID = firstDimension
        index = WorldIndexStore(readers: readers, work: backgroundWork, firstDimension: firstDimension, playerRoster: playerRoster)
        watcher = watchWorld(snapshot.access.url) { [weak self] in self?.worldChanged($0) }
        assetObserver = names.minecraft.observeChanges { [weak self] change in
            switch change {
            case .source: self?.refreshGameAssets()
            case .artwork: self?.refreshGameArtwork()
            }
        }
        refreshGameLanguage()
        refreshBiomeColors(reload: true)
        refreshLighting()
        if let root = cacheRoot, let folder = TileCache.worldFolder(forWorldAt: snapshot.access.url, root: root) {
            backgroundWork.start(priority: .background) {
                await Self.runCacheMaintenance(maintainCache, root: root, folder: folder)
            }
        }
    }

    /// Fresh metadata extends the catalog without replacing readers or any attached tab's map.
    /// The snapshot's own access remains the caller's; this world keeps its original root access.
    func includeDimensions(from prepared: WorldPreparation) {
        guard !isClosed else { return }
        let snapshot = prepared.snapshot
        let known = Set(dimensions.map(\.id))
        let added = snapshot.dimensions.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        let newIDs = Set(added.map(\.id))
        for id in newIDs { details.definitions.dimensionSettings[id] = snapshot.details.dimensionSettings[id] }
        dimensionDocuments.merge(snapshot.dimensionDocuments.filter { newIDs.contains($0.value) }) { old, _ in old }
        index.include(added.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot),
                         options: RegionReader.options(context: MapSurfaceContext(settings: details.dimensionSettings[dimension.id], water: details.definitions.water), definitions: details.definitions),
                         notableBlocks: details.definitions.notableBlocks,
                         structureGroups: details.definitions.structureGroups,
                         read: readRegion)
        }, firstDimension: activeDimensionID)
        refreshNightLighting(reread: true)
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
        darkSpotsVisibilityChanged()
        if let id = session.selectedDimensionID, let pending = pendingActions.removeValue(forKey: id) { pending.action(session) }
    }

    /// Multiple dimension views can observe the same source change. Retire it once for the
    /// world; opening another tab must not clear its siblings' color snapshot.
    func prepareGameAssets(_ source: WorldGameAssetSource) {
        guard !isClosed, source.generation == names.minecraft.generation, gameAssetSource != source else { return }
        // Retire values before publishing the new source token, so synchronous observers
        // cannot reconnect the old archive under the new source.
        gameAssets = nil
        gameAssetSource = source
        assetReadGeneration += 1
        assetWork.cancel()
        isAssetReadPending = false
        refreshGameLanguage()
        refreshBiomeColors(reload: true)
        refreshLighting()
        refreshNightLighting(reread: true)
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
            let unchanged = self.gameAssets?.identity == library?.identity
            self.setGameAssets(library, source: source)
            // A newly installed language object need not change the selected jar.
            if unchanged { self.refreshGameLanguage(reload: true) }
        }
    }

    func setGameAssets(_ library: GameResourceLibrary?, source: WorldGameAssetSource) {
        guard !isClosed, source.generation == names.minecraft.generation,
              gameAssetSource == source, gameAssets?.identity != library?.identity else { return }
        gameAssets = library
        refreshGameLanguage()
        refreshBiomeColors(reload: true)
        refreshNightLighting(reread: true)
        refreshLighting()
        refreshDefinitions()
    }

    func gameArtworkLibrary(for source: WorldGameAssetSource) -> GameArtworkLibrary? {
        guard !isClosed, source == gameAssetSource, source.generation == names.minecraft.generation else { return nil }
        return gameArtwork
    }

    /// Artwork policy retires drawing results immediately, including hidden tabs. Definitions,
    /// saved facts and their work retain the selected game library and source identity.
    private func refreshGameArtwork() {
        guard !isClosed else { return }
        refreshBiomeColors(reload: true)
    }

    var gameNames: GameNames {
        guard !isClosed, gameAssetSource?.generation == names.minecraft.generation,
              languageLoader.source == languageSource else { return .unavailable }
        return languageLoader.value ?? .unavailable
    }

    func refreshGameLanguage(preferredLanguage: String? = nil, reload: Bool = false) {
        guard !isClosed else { return }
        if let preferredLanguage { languagePreference = preferredLanguage }
        languageLoader.request(source: languageSource, isEnabled: true, reread: reload)
    }

    var newerWorldNotice: WorldVersionNotice? {
        guard !isClosed, gameAssetSource?.generation == names.minecraft.generation,
              let data = gameData else { return nil }
        return WorldVersionNotice(saved: savedVersion, game: data.version)
    }

    var newerWorldBanner: WorldVersionNotice? {
        guard let notice = newerWorldNotice,
              visibleNewerWorldNoticeID == notice.id || !settings.hasShownVersionNotice(notice.id) else { return nil }
        return notice
    }

    func presentNewerWorldNotice(_ notice: WorldVersionNotice) {
        guard newerWorldBanner == notice else { return }
        visibleNewerWorldNoticeID = notice.id
        settings.recordVersionNotice(notice.id)
    }

    func dismissNewerWorldNotice(_ notice: WorldVersionNotice) {
        guard newerWorldNotice == notice else { return }
        settings.recordVersionNotice(notice.id)
        visibleNewerWorldNoticeID = nil
    }

    nonisolated struct DefinitionSnapshot: Sendable {
        let definitions: WorldDefinitions
        let borders: [String: WorldBorder]
        let savedVersion: SavedMinecraftVersion
    }

    func playerRecords(for uuid: UUID, name: String?) async -> PlayerRecords? {
        guard !isClosed, !Task.isCancelled else { return nil }
        let generation = definitionReadGeneration, library = gameData, source = names.minecraft.generation
        var records = await readPlayerRecords(world, uuid, name, library)
        guard !Task.isCancelled, !isClosed, generation == definitionReadGeneration,
              source == names.minecraft.generation, gameData?.identity == library?.identity else { return nil }
        records.definitionGeneration = generation
        return records
    }

    private func refreshDefinitions() {
        guard !isClosed else { return }
        definitionReadGeneration += 1
        playerReadGeneration += 1
        let generation = definitionReadGeneration, library = gameData, read = readDefinitions, world = world
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
                  self.gameData?.identity == library?.identity else { return }
            self.isDefinitionReadPending = false
            self.savedVersion = updated.savedVersion
            // Keep the last coherent snapshot during a transient unreadable save. Never pair
            // new region definitions with players whose maximum used the previous definitions.
            guard let players else { return }
            var previous = self.details.definitions
            self.details.definitions = updated.definitions
            self.details.borders = updated.borders
            self.playerRoster.publish(players)
            // Leaf membership only supplies a sheet shortcut. Publishing it must not replace
            // readers or rescan regions; existing explicit block choices remain unchanged.
            previous.leafTag = updated.definitions.leafTag
            guard previous != updated.definitions else { return }
            let retired = self.index.readers
            let readers = retired.map { reader in
                let dimension = reader.dimension
                return RegionReader(dimension: dimension,
                    cache: ScanCache(forWorldAt: self.url, dimensionID: dimension.id, root: self.cacheRoot),
                    options: RegionReader.options(context: MapSurfaceContext(settings: updated.definitions.dimensionSettings[dimension.id], water: updated.definitions.water), definitions: updated.definitions),
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

    @concurrent nonisolated static func readDefinitions(_ world: World, library: GameDataLibrary?) async throws -> DefinitionSnapshot {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        let definitions: WorldDefinitions
        if let library { definitions = try await library.definitions(in: current) }
        else { definitions = try WorldDefinitions.read(current, assets: nil) }
        var borders: [String: WorldBorder] = [:]
        for dimension in current.dimensions() { borders[dimension.id] = try? current.worldBorder(of: dimension) }
        try Task.checkCancellation()
        return DefinitionSnapshot(definitions: definitions, borders: borders, savedVersion: SavedMinecraftVersion(current.level))
    }

    private func refreshBiomeColors(reload: Bool) {
        guard !isClosed else { return }
        biomeLoader.request(source: biomeSource, isEnabled: true, refresh: reload ? .contents : .metadata)
    }

    @concurrent nonisolated static func readBiomeColors(_ world: World, data: GameDataLibrary?,
                                                       artwork: GameArtworkLibrary?, previous: MapBiomeColors?,
                                                       reload: Bool) async throws -> MapBiomeColors {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        let source = GameResourceSource(data: data, artwork: artwork)
        if !reload, let previous, try previous.matchesMetadata(current, source: source) { return previous }
        if let data { return try await data.biomeColors(in: current, artwork: artwork) }
        return try MapBiomeColors.read(in: current, source: source, assets: nil)
    }

    /// Optional gameplay light metadata is shared by all interested dimension tabs. Ordinary
    /// windows do not start this read, and hiding the last layer cancels its current request.
    func darkSpotsVisibilityChanged() {
        refreshNightLighting(reread: false)
    }

    func nightLighting(in dimension: String) -> MonsterSpawnLight? {
        nightLightingLoader.value?[dimension]
    }

    private func refreshNightLighting(reread: Bool) {
        guard !isClosed else { return }
        nightLightingLoader.request(source: LightingSource(generation: names.minecraft.generation, library: gameData),
                                    isEnabled: sessions.values.contains { $0.value?.map?.showsDarkSpots == true },
                                    reread: reread)
    }

    func savedLighting(in dimension: String) -> MapLighting? {
        lightingLoader.value?[dimension]
    }

    private func refreshLighting() {
        guard !isClosed else { return }
        lightingLoader.request(source: LightingSource(generation: names.minecraft.generation, library: gameData),
                               isEnabled: true, reread: true)
    }

    @concurrent nonisolated static func readNightLighting(_ world: World, library: GameDataLibrary?) async throws -> [String: MonsterSpawnLight] {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        if let library { return try await library.nightLighting(in: current) }
        return try current.nightMonsterLighting(assets: nil)
    }

    @concurrent nonisolated static func readLighting(_ world: World, library: GameDataLibrary?) async throws -> [String: MapLighting] {
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
        languageLoader.close()
        biomeLoader.close()
        nightLightingLoader.close()
        lightingLoader.close()
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

    /// Register even a single inspector read so world access lasts until cancellation drains.
    func headingBlock(at position: BlockPosition, in dimensionID: String) async -> BlockState? {
        guard !isClosed, !Task.isCancelled,
              let dimension = dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        let read = readHeadingBlock
        var block: BlockState?
        guard let task = backgroundWork.start(priority: .utility, operation: {
            guard !Task.isCancelled else { return }
            block = try? await read(dimension, position)
        }) else { return nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !isClosed, !Task.isCancelled else { return nil }
        return block
    }

    @concurrent private nonisolated static func readBlock(_ dimension: ChunkseeKit.Dimension,
                                                         at position: BlockPosition) async throws -> BlockState? {
        try Task.checkCancellation()
        return try dimension.block(at: position)
    }

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
        await backgroundWork.waitUntilFinished(in: [refreshWork, biomeLoader.work, nightLightingLoader.work, lightingLoader.work, definitionsWork, assetWork, languageLoader.work])
        await index.waitForProjection()
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
            refreshNightLighting(reread: true)
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
