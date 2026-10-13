import Foundation
import ChunkseeKit
import Observation

/// One world's access and reads, shared by its open dimension documents, each of which owns only
/// its presentation. Closing the last of them closes the world.
@Observable
final class WorldResources {
    let access: WorldReadAccess
    let world: World
    let dimensions: [ChunkseeKit.Dimension]
    let details: WorldDetails
    let names: PlayerNames
    let savedSearches: SavedSearches
    let savedPlaces: SavedPlaces
    let readers: [String: RegionReader]
    let index: WorldIndexStore
    let views: RememberedViews
    let defaults: UserDefaults
    let cacheRoot: URL?
    private(set) var players: [PlayerInfo]
    var activeDimensionID: String?
    private(set) var isClosed = false
    @ObservationIgnored private var sessions: [UUID: WeakSession] = [:]
    /// Jumps waiting for a dimension's document to open.
    @ObservationIgnored private var pendingActions: [String: (id: UUID, action: (WorldSession) -> Void)] = [:]
    @ObservationIgnored private var retiringViews: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: WorldWatcher?
    @ObservationIgnored private var pendingRegions: [String: Set<RegionCoordinate>] = [:]
    @ObservationIgnored private var pendingDimensions: Set<String> = []
    @ObservationIgnored private var pendingPlayers = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)
    @ObservationIgnored private var isRefreshScheduled = false
    @ObservationIgnored private var playerReadGeneration = 0
    /// Reads the world's player files off the main actor; tests substitute a controlled read.
    @ObservationIgnored var readPlayers: @Sendable (World) async -> [PlayerInfo] = { await WorldResources.readPlayers($0) }

    private final class WeakSession {
        weak var value: WorldSession?
        init(_ value: WorldSession) { self.value = value }
    }

    var url: URL { access.url }
    var defaultDimensionID: String? {
        views.lastDimension.flatMap { id in dimensions.first { $0.id == id }?.id } ?? dimensions.first?.id
    }

    init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
         defaults: UserDefaults = .standard, cacheRoot: URL? = TileCache.root,
         readRegion: @escaping @Sendable (ChunkseeKit.Dimension, RegionCoordinate) async -> RegionData = RegionData.read) {
        access = snapshot.access
        world = snapshot.world
        dimensions = snapshot.dimensions
        details = snapshot.details
        players = snapshot.players
        self.names = names
        self.savedSearches = savedSearches
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        views = RememberedViews(world: snapshot.access.url, defaults: defaults)
        savedPlaces = SavedPlaces(world: snapshot.access.url, defaults: defaults)
        readers = Dictionary(uniqueKeysWithValues: snapshot.dimensions.map { dimension in
            (dimension.id, RegionReader(dimension: dimension,
                                       cache: ScanCache(forWorldAt: snapshot.access.url, dimensionID: dimension.id, root: cacheRoot),
                                       read: readRegion))
        })
        let last = views.lastDimension.flatMap { id in snapshot.dimensions.first { $0.id == id }?.id }
        let firstDimension = last ?? snapshot.dimensions.first?.id
        activeDimensionID = firstDimension
        index = WorldIndexStore(readers: Array(readers.values), firstDimension: firstDimension)
        watcher = WorldWatcher(folder: snapshot.access.url) { [weak self] in self?.worldChanged($0) }
        if let root = cacheRoot, let folder = TileCache.worldFolder(forWorldAt: snapshot.access.url, root: root) {
            Task.detached(priority: .background) {
                TileCache.markUsed(worldFolder: folder)
                TileCache.prune(root: root, limit: 1 << 30, keeping: folder)
            }
        }
    }

    func attach(_ session: WorldSession) {
        sessions[session.viewID] = WeakSession(session)
        if let id = session.selectedDimensionID, let pending = pendingActions.removeValue(forKey: id) { pending.action(session) }
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

    func detach(_ session: WorldSession, draining task: Task<Void, Never>) {
        sessions[session.viewID] = nil
        let id = session.viewID
        retiringViews[id] = task
        Task { [weak self] in
            await task.value
            self?.retiringViews[id] = nil
        }
        if sessions.values.allSatisfy({ $0.value == nil }) { close() }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingActions = [:]
        watcher?.stop()
        refreshTasks.values.forEach { $0.cancel() }
        index.cancel()
        for session in sessions.values.compactMap(\.value) { session.close() }
        let readers = Array(readers.values), index = index, retiring = Array(retiringViews.values)
        let refresh = Array(refreshTasks.values), access = access
        closingTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for reader in readers { group.addTask { await reader.close() } }
            }
            await index.waitForTasks()
            for task in retiring + refresh { await task.value }
            access.release()
        }
    }

    func waitUntilClosed() async { await closingTask?.value }

    func worldChanged(_ files: [URL]) {
        guard !isClosed else { return }
        for file in files.map(\.standardizedFileURL) {
            let path = file.path
            if path.hasPrefix(world.playerDataDirectory.standardizedFileURL.path + "/") {
                pendingPlayers = true
            } else if let dimension = dimensions.filter({ path.hasPrefix($0.url.standardizedFileURL.path + "/") })
                .max(by: { $0.url.path.count < $1.url.path.count }) {
                // Nether, End and custom dimension folders can sit inside the Overworld folder.
                pendingDimensions.insert(dimension.id)
                if file.deletingLastPathComponent().path == dimension.regionDirectory.standardizedFileURL.path,
                   let region = RegionFile.parseCoordinates(file.lastPathComponent) {
                    pendingRegions[dimension.id, default: []].insert(RegionCoordinate(x: region.x, z: region.z))
                }
            }
        }
        guard !pendingDimensions.isEmpty || pendingPlayers else { return }
        // While a player explores, the game saves region files every second or so. Changes join
        // the refresh already scheduled rather than postponing it, so the map catches up every
        // `refreshDelay` during play instead of only once the game goes quiet.
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        let delay = refreshDelay, id = UUID()
        let task = Task { [weak self] in
            defer { self?.refreshTasks[id] = nil }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Changes from here on schedule the next refresh.
            self.isRefreshScheduled = false
            await self.refresh()
        }
        refreshTask = task
        refreshTasks[id] = task
    }

    /// Waits for every refresh under way, including one still reading players behind a newer one.
    func waitForRefresh() async {
        while let task = refreshTasks.values.first { await task.value }
    }

    private func refresh() async {
        let regions = pendingRegions, changed = pendingDimensions, playersChanged = pendingPlayers
        pendingRegions = [:]; pendingDimensions = []; pendingPlayers = false
        for session in sessions.values.compactMap(\.value) {
            if let id = session.selectedDimensionID, changed.contains(id) {
                session.map?.regionsChanged(regions[id] ?? [])
                session.heatMap.load(reread: true)
            }
        }
        if !changed.isEmpty { index.rebuild(firstDimension: activeDimensionID) }
        if playersChanged {
            // Refreshes can overlap while one reads players, so only the newest read is published:
            // an older, slower read finishing later must not put old positions back.
            playerReadGeneration += 1
            let generation = playerReadGeneration
            let updated = await readPlayers(world)
            guard !Task.isCancelled, !isClosed, generation == playerReadGeneration else { return }
            players = updated
            for session in sessions.values.compactMap(\.value) { session.search.players = updated }
        }
    }

    @concurrent nonisolated static func readPlayers(_ world: World) async -> [PlayerInfo] { world.players() }
}
