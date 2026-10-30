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
    @ObservationIgnored private(set) var access: WorldReadAccess
    private(set) var readSource: WorldReadSource
    let backgroundWork: BackgroundWork
    var world: World { infoSnapshot.world }
    var savedVersion: SavedMinecraftVersion { SavedMinecraftVersion(world.level) }
    private var visibleNewerWorldNoticeID: String?
    var dimensions: [ChunkseeKit.Dimension] { index.readers.map(\.dimension) }
    private(set) var dimensionDocuments: [String: String]
    private let openingInfo: WorldInfoSnapshot
    private let openingMaps: WorldMapSnapshot
    var infoSnapshot: WorldInfoSnapshot { infoLoader.value ?? WorldInfoSnapshot(world: readSource.world) }
    var details: WorldDetails {
        WorldDetails(definitions: definitionLoader.value?.definitions ?? WorldDefinitions(),
                     info: infoSnapshot, mapSnapshot: mapLoader.value ?? WorldMapSnapshot(sources: []))
    }
    let names: PlayerNames
    let savedSearches: SavedSearches
    let savedPlaces: SavedPlaces
    var readers: [String: RegionReader] { Dictionary(uniqueKeysWithValues: index.readers.map { ($0.dimension.id, $0) }) }
    let index: WorldIndexStore
    @ObservationIgnored private(set) lazy var queryStore = WorldQueryStore(
        index: index, work: backgroundWork, names: names, savedSearches: savedSearches,
        singleplayerUUID: { [weak self] in self?.world.level.singleplayerUUID },
        gameNames: { [weak self] in self?.gameNames ?? .unavailable })
    let settings: WorldSettings
    let cacheRoot: URL?
    private let definitionLoader: WorldDefinitionLoader
    @ObservationIgnored private lazy var infoLoader = RefreshLoader<WorldInfoSource, RefreshInvalidation, WorldInfoSnapshot>(
        partialRead: { [weak self] source, _, previous in
            guard let read = await self?.readInfo else { throw CancellationError() }
            return try await read(source, previous)
        }, work: backgroundWork, priority: .utility, whenInactive: .finish, source: infoSource,
        initialValue: openingInfo, firstRequest: .refresh, merge: { _, newer in newer },
        retainingValue: { value, previous, current in
            guard previous.worldSource == current.worldSource else { return nil }
            let old = Dictionary(uniqueKeysWithValues: previous.dimensions.map { ($0.id, $0.url) })
            let unchanged = Set(current.dimensions.filter { old[$0.id] == $0.url }.map(\.id))
            var retained = value
            retained.borders = retained.borders.filter { unchanged.contains($0.key) }
            return retained
        }
    )
    @ObservationIgnored var readInfo: @Sendable (WorldInfoSource, WorldInfoSnapshot?) async throws -> RefreshRead<WorldInfoSnapshot> = {
        try await $0.read(retaining: $1)
    }
    private var infoSource: WorldInfoSource {
        .init(worldSource: readSource, dimensions: dimensions.sorted { $0.id < $1.id })
    }
    private func refreshInfo() {
        guard !isClosed else { return }
        infoLoader.request(source: infoSource, isEnabled: true, refresh: .refresh)
    }
    @ObservationIgnored private lazy var mapLoader = RefreshLoader<WorldMapSource, RefreshInvalidation, WorldMapSnapshot>(
        partialRead: { [weak self] source, _, previous in
            guard let read = await self?.readMaps else { throw CancellationError() }
            return try await read(source, previous)
        }, work: backgroundWork, priority: .utility, whenInactive: .finish,
        source: WorldMapSource(worldSource: readSource), initialValue: openingMaps,
        firstRequest: .refresh, merge: { _, newer in newer }
    )
    @ObservationIgnored var readMaps: @Sendable (WorldMapSource, WorldMapSnapshot?) async throws -> RefreshRead<WorldMapSnapshot> = {
        try await $0.read(retaining: $1)
    }
    private func refreshMaps() {
        guard !isClosed else { return }
        mapLoader.request(source: WorldMapSource(worldSource: readSource), isEnabled: true, refresh: .refresh)
    }
    var playerRoster: any PlayerSnapshotSource { definitionLoader }
    var playerSnapshot: PlayerSnapshot { playerRoster.snapshot }
    var players: [PlayerInfo] { playerSnapshot.players }
    private let makeReader: (WorldReadSource, ChunkseeKit.Dimension, WorldDefinitions) -> RegionReader
    private let watchWorld: @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher?
    private let maintainCache: @Sendable (URL, URL) async -> Void
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
    @ObservationIgnored private var pendingWorldData = false
    @ObservationIgnored private var pendingPlayers = false
    @ObservationIgnored private var pendingLighting = false
    @ObservationIgnored private var pendingBiomeMetadata = false
    @ObservationIgnored private var pendingBiomePacks = false
    private let refreshWork: BackgroundWork.Scope
    private let assetLoader: RefreshLoader<WorldGameAssetSource, RefreshInvalidation, GameAssetSelection>
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
    var readDefinitions: WorldDefinitionLoader.ReadDefinitions {
        get { definitionLoader.readDefinitions }
        set { definitionLoader.readDefinitions = newValue }
    }
    @ObservationIgnored private(set) lazy var playerRecords = PlayerRecordStore(world: readSource, work: backgroundWork, names: names) { [weak self] in
        guard let self, !self.isClosed else { return nil }
        return self.gameSource
    }
    @ObservationIgnored private lazy var nightLightingLoader = RefreshLoader(
        work: backgroundWork, priority: nil, whenInactive: .cancel,
        source: LightingSource(world: readSource, generation: names.minecraft.generation, library: gameData)
    ) { [weak self] source, _ in
        guard let read = await self?.readNightLighting else { throw CancellationError() }
        return try await read(source.world.world, source.library)
    }
    @ObservationIgnored var readNightLighting: @Sendable (World, GameDataLibrary?) async throws -> [String: MonsterSpawnLight] = {
        try await WorldResources.readNightLighting($0, library: $1)
    }
    nonisolated private struct LightingSource: Equatable, Sendable {
        let world: WorldReadSource
        let generation: UUID
        let library: GameDataLibrary?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.world == rhs.world && lhs.generation == rhs.generation && lhs.library === rhs.library
        }
    }
    @ObservationIgnored private lazy var lightingLoader = RefreshLoader(
        work: backgroundWork, priority: nil, whenInactive: .finish,
        source: LightingSource(world: readSource, generation: names.minecraft.generation, library: gameData)
    ) { [weak self] source, _ in
        guard let read = await self?.readLighting else { throw CancellationError() }
        return try await read(source.world.world, source.library)
    }
    @ObservationIgnored var readLighting: @Sendable (World, GameDataLibrary?) async throws -> [String: MapLighting] = {
        try await WorldResources.readLighting($0, library: $1)
    }
    /// A completed read can explicitly find no library; nil loader value means not yet read.
    nonisolated private struct GameAssetSelection: Sendable {
        let library: GameResourceLibrary?
    }
    private var gameAssets: GameResourceLibrary? {
        guard !isClosed, assetLoader.source.generation == names.minecraft.generation else { return nil }
        return assetLoader.value?.library
    }
    private var gameData: GameDataLibrary? { gameAssets?.data }
    private var gameArtwork: GameArtworkLibrary? { names.minecraft.artwork(for: gameAssets) }
    var mapGameResources: MapGameResources {
        guard !isClosed else { return .unavailable }
        return MapGameResources(data: gameData, artwork: gameArtwork, biomeColors: biomeColors)
    }
    var biomeColors: MapBiomeColors? {
        guard !isClosed, biomeLoader.source == biomeSource else { return nil }
        return biomeLoader.value
    }
    @ObservationIgnored private lazy var biomeLoader = RefreshLoader<BiomeSource, BiomeRequest, MapBiomeColors>(
        work: backgroundWork, priority: nil, whenInactive: .finish, source: biomeSource,
        firstRequest: .metadata, merge: { $0.merging($1) }, retainingValue: { value, previous, current in
            guard previous.world == current.world, previous.generation == current.generation, previous.data === current.data else { return nil }
            return value.removingArtwork()
        }
    ) { [weak self] source, request, previous in
        guard let read = await self?.readBiomeColors else { throw CancellationError() }
        return try await read(source.world.world, source.data, source.artwork, previous, request == .contents)
    }
    nonisolated private enum BiomeRequest: Equatable, Sendable {
        case metadata, contents
        func merging(_ other: Self) -> Self { self == .contents || other == .contents ? .contents : .metadata }
    }
    nonisolated private struct BiomeSource: Equatable, Sendable {
        let world: WorldReadSource
        let generation: UUID
        let data: GameDataLibrary?
        let artwork: GameArtworkLibrary?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.world == rhs.world && lhs.generation == rhs.generation && lhs.data === rhs.data && lhs.artwork === rhs.artwork
        }
    }
    private var biomeSource: BiomeSource {
        BiomeSource(world: readSource, generation: names.minecraft.generation, data: gameData, artwork: gameArtwork)
    }
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)
    /// Tests can hold this boundary without making refresh correctness depend on scheduler speed.
    @ObservationIgnored var waitBeforeRefresh: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private var isRefreshScheduled = false
    /// Reads the world's player files off the main actor; tests substitute a controlled read.
    var readPlayers: WorldDefinitionLoader.ReadPlayers {
        get { definitionLoader.readPlayers }
        set { definitionLoader.readPlayers = newValue }
    }
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

    var url: URL { readSource.world.url }
    var defaultDimensionID: String? {
        settings.lastDimension.flatMap { id in dimensions.first { $0.id == id }?.id } ?? dimensions.first?.id
    }

    /// Tests that inject file changes substitute the watcher so real notifications cannot race
    /// their controlled events. Documents use the normal FSEvents source and own its lifetime here.
    init(prepared: WorldPreparation, names: PlayerNames, savedSearches: SavedSearches,
         settings: WorldSettings, cacheRoot: URL?,
         watchWorld: @escaping @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = WorldWatcher.init,
         readRegion: @escaping RegionReader.Read = RegionReader.scan,
         readGameAssets: @escaping @Sendable (MinecraftResources) async throws -> GameResourceLibrary? = { try await $0.readLibrary() },
         maintainCache: @escaping @Sendable (URL, URL) async -> Void = WorldResources.maintainCache) {
        let snapshot = prepared.snapshot
        let readSource = WorldReadSource(snapshot.world)
        self.readSource = readSource
        self.watchWorld = watchWorld
        self.maintainCache = maintainCache
        let backgroundWork = BackgroundWork()
        self.backgroundWork = backgroundWork
        refreshWork = backgroundWork.makeScope()
        let definitionLoader = WorldDefinitionLoader(world: readSource, work: backgroundWork,
            gameSource: .init(generation: prepared.source.generation, selection: .loaded(prepared.library?.data)),
            dimensions: snapshot.dimensions,
            definitions: snapshot.details.definitions, players: snapshot.players)
        self.definitionLoader = definitionLoader
        assetLoader = RefreshLoader(work: backgroundWork, priority: .utility, whenInactive: .finish,
            source: prepared.source, initialValue: GameAssetSelection(library: prepared.library)
        ) { [minecraft = names.minecraft] source, _ in
            guard await minecraft.generation == source.generation else { throw CancellationError() }
            let library = try await readGameAssets(minecraft)
            guard await minecraft.generation == source.generation else { throw CancellationError() }
            return GameAssetSelection(library: library)
        }
        access = snapshot.access
        dimensionDocuments = snapshot.dimensionDocuments
        openingInfo = snapshot.details.info
        openingMaps = snapshot.details.mapSnapshot
        self.names = names
        self.savedSearches = savedSearches
        self.cacheRoot = cacheRoot
        let makeReader = { (source: WorldReadSource, dimension: ChunkseeKit.Dimension, definitions: WorldDefinitions) in
            RegionReader(dimension: dimension,
                cache: ScanCache(forWorldAt: source.world.url, dimensionID: dimension.id, root: cacheRoot),
                inputs: .init(dimensionID: dimension.id, definitions: definitions), read: readRegion)
        }
        self.makeReader = makeReader
        self.settings = settings
        savedPlaces = SavedPlaces(settings: settings)
        let readers = snapshot.dimensions.map { makeReader(readSource, $0, snapshot.details.definitions) }
        let last = settings.lastDimension.flatMap { id in snapshot.dimensions.first { $0.id == id }?.id }
        let firstDimension = last ?? snapshot.dimensions.first?.id
        activeDimensionID = firstDimension
        index = WorldIndexStore(readers: readers, work: backgroundWork, firstDimension: firstDimension, playerRoster: definitionLoader)
        definitionLoader.published = { [weak self] current in
            self?.adoptDefinitions(current)
        }
        assetLoader.published = { [weak self] previous, current in
            guard let self, !self.isClosed else { return }
            let sourceChanged = previous.source != current.source ||
                previous.value?.library?.identity != current.value?.library?.identity
            if sourceChanged {
                self.refreshGameLanguage()
                self.refreshBiomeColors(reload: true)
                self.refreshNightLighting(reread: true)
                self.refreshLighting()
            } else if current.value != nil {
                // A newly installed language object need not change the selected jar.
                self.refreshGameLanguage(reload: true)
            }
            if sourceChanged || (previous.value == nil && current.value != nil) {
                self.refreshDefinitions()
            }
        }
        watchCurrentSource()
        assetObserver = names.minecraft.observeChanges { [weak self] change in
            switch change {
            case .source: self?.refreshGameAssets()
            case .artwork: self?.refreshGameArtwork()
            }
        }
        refreshGameLanguage()
        refreshBiomeColors(reload: true)
        refreshLighting()
        maintainCurrentCache()
        _ = queryStore
    }

    private func watchCurrentSource() {
        let source = readSource
        watcher = watchWorld(url) { [weak self] files in
            guard let self, self.readSource == source else { return }
            self.worldChanged(files)
        }
    }

    private func maintainCurrentCache() {
        guard let root = cacheRoot, let folder = TileCache.worldFolder(forWorldAt: url, root: root) else { return }
        let maintain = maintainCache
        backgroundWork.start(priority: .background) {
            await Self.runCacheMaintenance(maintain, root: root, folder: folder)
        }
    }

    /// Native rereads and moves replace inputs for this same world and every attached window.
    /// Register old access retirement before publishing anything an observer could close.
    func replaceSource(with prepared: WorldPreparation) throws {
        guard !isClosed else { throw CancellationError() }
        let snapshot = prepared.snapshot, oldAccess = access, retired = index.readers
        let nextSource = WorldReadSource(snapshot.world)
        let readers = snapshot.dimensions.map { makeReader(nextSource, $0, snapshot.details.definitions) }
        watcher?.stop()
        refreshWork.cancel()
        isRefreshScheduled = false
        pendingIndex = [:]; pendingTerrain = [:]; pendingPlayers = false
        pendingWorldData = false; pendingLighting = false
        pendingBiomeMetadata = false; pendingBiomePacks = false
        for session in sessions.values.compactMap(\.value) { session.prepareWorldSourceReplacement() }
        guard !isClosed else { throw CancellationError() }
        backgroundWork.start(priority: .utility) {
            for reader in retired { await reader.close() }
        }
        backgroundWork.afterCurrentWork { oldAccess.release() }
        // From here this owner must release the incoming access, even if a synchronous
        // observer closes it. Throwing would make the caller release it before work drains.
        access = snapshot.access
        readSource = nextSource
        guard !isClosed else { return }
        // Install the prepared catalog before definition callbacks can replace its readers.
        // Completed compatible facts remain available while the new files are checked.
        index.replaceWorldSource(readers: readers, firstDimension: activeDimensionID)
        guard !isClosed else { return }
        dimensionDocuments = snapshot.dimensionDocuments
        infoLoader.replace(source: WorldInfoSource(worldSource: readSource, dimensions: snapshot.dimensions.sorted { $0.id < $1.id }),
                           value: snapshot.details.info)
        mapLoader.replace(source: WorldMapSource(worldSource: readSource), value: snapshot.details.mapSnapshot)
        playerRecords.replaceWorld(readSource)
        definitionLoader.replaceWorld(readSource,
            gameSource: .init(generation: prepared.source.generation, selection: .loaded(prepared.library?.data)),
            dimensions: snapshot.dimensions, definitions: snapshot.details.definitions, players: snapshot.players)
        assetLoader.replace(source: prepared.source, value: GameAssetSelection(library: prepared.library))
        guard !isClosed else { return }
        for session in sessions.values.compactMap(\.value) { session.replaceWorldSource() }
        guard !isClosed else { return }
        refreshBiomeColors(reload: true)
        refreshNightLighting(reread: true)
        refreshLighting()
        watchCurrentSource()
        maintainCurrentCache()
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
        definitionLoader.include(added, settings: snapshot.details.dimensionSettings)
        guard !isClosed else { return }
        dimensionDocuments.merge(snapshot.dimensionDocuments.filter { newIDs.contains($0.value) }) { old, _ in old }
        index.include(added.map { makeReader(readSource, $0, details.definitions) }, firstDimension: activeDimensionID)
        refreshInfo()
        refreshNightLighting(reread: true)
        refreshLighting()
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

    /// All dimension views share one source request. Permission changes also reach hidden tabs,
    /// whose SwiftUI tasks may not run until they become visible again.
    func refreshGameAssets() {
        guard !isClosed else { return }
        let source = WorldGameAssetSource(generation: names.minecraft.generation)
        assetLoader.request(source: source, isEnabled: true, reread: true)
    }

    func waitForGameAssets() async { await assetLoader.waitUntilFinished() }

    func gameArtworkLibrary(for source: WorldGameAssetSource) -> GameArtworkLibrary? {
        guard !isClosed, source == assetLoader.source, source.generation == names.minecraft.generation else { return nil }
        return gameArtwork
    }

    /// Artwork policy retires drawing results immediately, including hidden tabs. Definitions,
    /// saved facts and their work retain the selected game library and source identity.
    private func refreshGameArtwork() {
        guard !isClosed else { return }
        refreshBiomeColors(reload: true)
    }

    var gameNames: GameNames {
        guard !isClosed else { return .unavailable }
        let names: GameNames
        if assetLoader.source.generation == self.names.minecraft.generation,
           languageLoader.source == languageSource {
            names = languageLoader.value ?? .unavailable
        } else {
            names = .unavailable
        }
        let source = gameSource
        guard source.selection.isLoaded, let facts = definitionLoader.value,
              facts.source == source.identity else { return names }
        return names.withEnchantments(facts.enchantmentNames)
    }

    func refreshGameLanguage(preferredLanguage: String? = nil, reload: Bool = false) {
        guard !isClosed else { return }
        if let preferredLanguage { languagePreference = preferredLanguage }
        languageLoader.request(source: languageSource, isEnabled: true, reread: reload)
    }

    var newerWorldNotice: WorldVersionNotice? {
        guard !isClosed, assetLoader.source.generation == names.minecraft.generation,
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

    private var gameSource: WorldGameDataSource {
        let selection: WorldGameDataSource.Selection
        if assetLoader.source.generation == names.minecraft.generation, let loaded = assetLoader.value {
            selection = .loaded(loaded.library?.data)
        } else {
            selection = .loading
        }
        return WorldGameDataSource(generation: names.minecraft.generation, selection: selection)
    }

    private func refreshDefinitions() {
        guard !isClosed else { return }
        definitionLoader.refreshDefinitions(gameSource: gameSource)
    }

    private func adoptDefinitions(_ current: WorldDefinitionLoader.Facts?) {
        guard !isClosed else { return }
        let definitions = current?.definitions ?? WorldDefinitions()
        let retired = index.readers
        guard retired.contains(where: {
            $0.inputs != RegionReader.Inputs(dimensionID: $0.dimension.id, definitions: definitions)
        }) else { return }
        let readers = retired.map { makeReader(readSource, $0.dimension, definitions) }
        // Register retirement before publishing the replacement catalog: an observer may close
        // the world synchronously, and that close must drain the retired readers too.
        backgroundWork.start(priority: .utility) {
            for reader in retired { await reader.close() }
        }
        index.replace(readers: readers, firstDimension: activeDimensionID)
    }

    @concurrent nonisolated static func readDefinitions(_ world: World, library: GameDataLibrary?) async throws -> WorldDefinitions {
        try Task.checkCancellation()
        let current = try World(contentsOf: world.url)
        let definitions: WorldDefinitions
        if let library { definitions = try await library.definitions(in: current) }
        else { definitions = try WorldDefinitions.read(current, assets: nil) }
        try Task.checkCancellation()
        return definitions
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
        nightLightingLoader.request(source: LightingSource(world: readSource, generation: names.minecraft.generation, library: gameData),
                                    isEnabled: sessions.values.contains { $0.value?.map?.showsDarkSpots == true },
                                    reread: reread)
    }

    func savedLighting(in dimension: String) -> MapLighting? {
        lightingLoader.value?[dimension]
    }

    private func refreshLighting() {
        guard !isClosed else { return }
        lightingLoader.request(source: LightingSource(world: readSource, generation: names.minecraft.generation, library: gameData),
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
            var presentation = settings.mapPresentation(for: dimension)
            presentation.overlays.showsSavedPlaces = true
            settings.save(presentation, for: dimension)
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
        queryStore.close()
        index.cancel()
        for session in sessions.values.compactMap(\.value) { session.close() }
        assetLoader.close()
        languageLoader.close()
        biomeLoader.close()
        nightLightingLoader.close()
        lightingLoader.close()
        infoLoader.close()
        mapLoader.close()
        definitionLoader.close()
        playerRecords.close()
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
        let read = readHeadingBlock, source = readSource
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
        guard !isClosed, !Task.isCancelled, readSource == source else { return nil }
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
            var mayChangeSavedData = true
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
                    mayChangeSavedData = false
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
                    mayChangeSavedData = path == dimension.url.standardizedFileURL.path
                    pendingIndex[dimension.id] = .all
                    pendingTerrain[dimension.id] = .all
                }
            }
            // Kit owns saved-data discovery, including older layouts and missing files.
            // Non-region changes invalidate world facts and requested player records without
            // copying those discovery tables here. Ordinary region writes do not reread them.
            pendingWorldData = pendingWorldData || mayChangeSavedData
        }
        guard pendingWorldData || !pendingIndex.isEmpty || pendingPlayers || pendingBiomeMetadata || pendingBiomePacks || pendingLighting else { return }
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

    /// Waits for active and coalesced refresh passes, without waiting for unrelated world work.
    func waitForRefresh() async {
        await backgroundWork.waitUntilFinished(in: [refreshWork, biomeLoader.work, nightLightingLoader.work, lightingLoader.work, definitionLoader.work, infoLoader.work, mapLoader.work, assetLoader.work, languageLoader.work])
        await playerRecords.waitUntilFinished()
        await index.waitForProjection()
    }

    private func refresh() async {
        let changed = pendingIndex, terrain = pendingTerrain, playersChanged = pendingPlayers
        let biomesChanged = pendingBiomeMetadata || pendingBiomePacks, reloadBiomes = pendingBiomePacks
        let lightingChanged = pendingLighting, worldDataChanged = pendingWorldData
        pendingLighting = false
        pendingWorldData = false
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
        if worldDataChanged { refreshInfo(); refreshMaps(); playerRecords.refresh() }
        if biomesChanged {
            refreshDefinitions()
        } else if playersChanged {
            definitionLoader.refreshPlayers()
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
