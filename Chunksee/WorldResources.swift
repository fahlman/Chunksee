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
    private let refreshWork: BackgroundWork.Scope
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)
    @ObservationIgnored private var isRefreshScheduled = false
    @ObservationIgnored private var playerReadGeneration = 0
    /// Reads the world's player files off the main actor; tests substitute a controlled read.
    @ObservationIgnored var readPlayers: @Sendable (World) async -> [PlayerInfo]? = { await WorldResources.readPlayers($0) }

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
         defaults: UserDefaults, cacheRoot: URL?,
         watchWorld: @MainActor (URL, @escaping ([URL]) -> Void) -> WorldWatcher? = WorldWatcher.init,
         readRegion: @escaping RegionReader.Read = RegionReader.scan,
         maintainCache: @escaping @Sendable (URL, URL) async -> Void = WorldResources.maintainCache) {
        let backgroundWork = BackgroundWork()
        self.backgroundWork = backgroundWork
        refreshWork = backgroundWork.makeScope()
        access = snapshot.access
        world = snapshot.world
        dimensionDocuments = snapshot.dimensionDocuments
        details = snapshot.details
        playerRoster = PlayerRoster(snapshot.players)
        self.names = names
        self.savedSearches = savedSearches
        self.cacheRoot = cacheRoot
        self.readRegion = readRegion
        settings = WorldSettings(world: snapshot.access.url, defaults: defaults)
        savedPlaces = SavedPlaces(settings: settings)
        let readers = snapshot.dimensions.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: snapshot.access.url, dimensionID: dimension.id, root: cacheRoot),
                         read: readRegion)
        }
        let last = settings.lastDimension.flatMap { id in snapshot.dimensions.first { $0.id == id }?.id }
        let firstDimension = last ?? snapshot.dimensions.first?.id
        activeDimensionID = firstDimension
        index = WorldIndexStore(readers: readers, work: backgroundWork, firstDimension: firstDimension)
        watcher = watchWorld(snapshot.access.url) { [weak self] in self?.worldChanged($0) }
        if let root = cacheRoot, let folder = TileCache.worldFolder(forWorldAt: snapshot.access.url, root: root) {
            backgroundWork.start(priority: .background) {
                await Self.runCacheMaintenance(maintainCache, root: root, folder: folder)
            }
        }
    }

    func relocateSettings(to world: URL) {
        settings.relocate(to: world)
        savedPlaces.reload()
    }

    /// Fresh metadata extends the catalog without replacing readers or any attached tab's map.
    /// The snapshot's own access remains the caller's; this world keeps its original root access.
    func includeDimensions(from snapshot: WorldSnapshot) {
        guard !isClosed else { return }
        let known = Set(dimensions.map(\.id))
        let added = snapshot.dimensions.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        let newIDs = Set(added.map(\.id))
        for id in newIDs { details.dimensionTypes[id] = snapshot.details.dimensionTypes[id] }
        dimensionDocuments.merge(snapshot.dimensionDocuments.filter { newIDs.contains($0.value) }) { old, _ in old }
        index.include(added.map { dimension in
            RegionReader(dimension: dimension,
                         cache: ScanCache(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot), read: readRegion)
        }, firstDimension: activeDimensionID)
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
        if let id = session.selectedDimensionID, let pending = pendingActions.removeValue(forKey: id) { pending.action(session) }
    }

    func saveViews() {
        guard !isClosed else { return }
        for session in sessions.values { session.value?.saveView() }
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
        closeIfUnused()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        openings = []
        pendingActions = [:]
        watcher?.stop()
        backgroundWork.close()
        index.cancel()
        for session in sessions.values.compactMap(\.value) { session.close() }
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
            } else if path == url.appendingPathComponent("level.dat").standardizedFileURL.path ||
                        path == world.playerDataDirectory.standardizedFileURL.path || path.hasPrefix(world.playerDataDirectory.standardizedFileURL.path + "/") {
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
        guard !pendingIndex.isEmpty || pendingPlayers else { return }
        // While a player explores, the game saves region files every second or so. Changes join
        // the refresh already scheduled rather than postponing it, so the map catches up every
        // `refreshDelay` during play instead of only once the game goes quiet.
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        let delay = refreshDelay
        refreshWork.start(priority: nil) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Changes from here on schedule the next refresh.
            self.isRefreshScheduled = false
            await self.refresh()
        }
    }

    /// Waits for every refresh under way, including one still reading players behind a newer one.
    func waitForRefresh() async {
        await refreshWork.waitUntilFinished()
    }

    private func refresh() async {
        let changed = pendingIndex, terrain = pendingTerrain, playersChanged = pendingPlayers
        pendingIndex = [:]; pendingTerrain = [:]; pendingPlayers = false
        for session in sessions.values.compactMap(\.value) {
            if let id = session.selectedDimensionID, let changes = terrain[id] {
                session.map?.regionsChanged(changes.mapRegions)
                session.heatMap.load(reread: true)
                session.slimeChunks.regionsChanged(session.map?.availableRegions ?? [])
            }
        }
        if !changed.isEmpty { index.rebuild(firstDimension: activeDimensionID, changes: changed) }
        if playersChanged {
            // Refreshes can overlap while one reads players, so only the newest read is published:
            // an older, slower read finishing later must not put old positions back.
            playerReadGeneration += 1
            let generation = playerReadGeneration
            let updated = await readPlayers(world)
            guard !Task.isCancelled, !isClosed, generation == playerReadGeneration, let updated else { return }
            playerRoster.publish(updated)
        }
    }

    @concurrent nonisolated static func readPlayers(_ world: World) async -> [PlayerInfo]? {
        // World keeps its opening level.dat snapshot, including the single-player fallback.
        // Reopen through Kit so a save updates that record too. An unreadable save must not
        // clear the last good players; a successful read with no players does clear them.
        guard !Task.isCancelled, let current = try? World(contentsOf: world.url) else { return nil }
        return current.players()
    }
}
