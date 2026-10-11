import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
    case storage
    case player(UUID)
}

/// The thing on the map whose card is showing; one at a time.
enum MapSelection: Equatable {
    case portal(NetherPortal)
    case creature(CreatureMarker)
    case inGameMap(MapItem)

    var dimension: String? {
        switch self {
        case .portal(let portal): portal.dimension
        case .creature(let creature): creature.dimension
        case .inGameMap(let map): map.dimension
        }
    }
}

/// The world the user opened, and the security-scoped access that lets the sandboxed app read it.
/// It coordinates the selected dimension's map with the parts that span the world: players,
/// portals, search, the heat map and live updates as the game saves.
@Observable
final class WorldSession {
    let url: URL
    let world: World
    let dimensions: [ChunkseeKit.Dimension]
    /// Game rules, weather, borders, in-game maps and the like, read when the world opens.
    let details: WorldDetails
    /// App-wide player names, shared across worlds.
    let names: PlayerNames
    let visibility: LayerVisibility
    let search: SearchModel
    /// Searches kept in the sidebar, shared across worlds.
    let savedSearches: SavedSearches
    let heatMap: HeatMapLayer
    let playerRecords: PlayerRecordsModel

    var selectedDimensionID: String? {
        didSet {
            guard oldValue != selectedDimensionID else { return }
            saveView(of: oldValue)   // the map still shows the dimension being left
            if let selection, selection.dimension != selectedDimensionID { self.selection = nil }
            heatMap.dimension = selectedDimensionID
            makeMapForSelection()
        }
    }
    private(set) var map: MapModel?
    /// Players with saved data, most recently saved first. Reread when the game saves them.
    private(set) var players: [PlayerInfo] {
        didSet { search.players = players }
    }
    /// What the inspector shows, if it's open.
    var inspector: Inspector? {
        didSet { if inspector != oldValue { playerRecords.cancel() } }
    }
    var showsCoordinateSheet = false
    var selection: MapSelection?
    /// How opaque a selected in-game map is over the terrain.
    var inGameMapOpacity = 0.85
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    var portalsByDimension: [String: [NetherPortal]] { search.portals }
    /// The selected dimension's part of the world index: what its sidebar lists and map show.
    var selectedIndex: DimensionIndex {
        selectedDimensionID.flatMap { search.index.dimensions[$0] } ?? DimensionIndex()
    }

    private let cacheRoot: URL?
    /// One per dimension: reads each region once for the index and the heat map.
    private let readers: [String: RegionReader]
    private let views: RememberedViews
    private let access: WorldReadAccess
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var retiringMaps: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]

    init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
         defaults: UserDefaults = .standard, cacheRoot: URL? = TileCache.root,
         readRegion: @escaping @Sendable (ChunkseeKit.Dimension, RegionCoordinate) async -> RegionData = RegionData.read) {
        let url = snapshot.access.url, world = snapshot.world, dimensions = snapshot.dimensions, players = snapshot.players
        let readers = Dictionary(uniqueKeysWithValues: dimensions.map { dimension in
            (dimension.id, RegionReader(dimension: dimension, cache: ScanCache(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot),
                                        read: readRegion))
        })
        self.url = url
        self.world = world
        self.dimensions = dimensions
        self.details = snapshot.details
        self.names = names
        self.players = players
        self.cacheRoot = cacheRoot
        self.readers = readers
        self.views = RememberedViews(world: url, defaults: defaults)
        self.access = snapshot.access
        self.visibility = LayerVisibility(defaults: defaults)
        self.savedSearches = savedSearches
        // Reopen in the dimension last viewed, if it still exists.
        let last = views.lastDimension.flatMap { id in dimensions.first { $0.id == id }?.id }
        let selected = last ?? dimensions.first?.id
        self.search = SearchModel(readers: dimensions.compactMap { readers[$0.id] }, players: players, names: names,
                                  singleplayerUUID: world.level.singleplayerUUID, firstDimension: selected, savedSearches: savedSearches)
        self.heatMap = HeatMapLayer(readers: readers)
        self.playerRecords = PlayerRecordsModel(world: world)
        self.selectedDimensionID = selected
        heatMap.dimension = selectedDimensionID
        makeMapForSelection()
        Self.maintainTileCache(forWorldAt: url, root: cacheRoot)
        watcher = WorldWatcher(folder: url) { [weak self] files in self?.worldChanged(files) }
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    /// `defaults` keeps which layers are shown and where the map was, and saved searches unless
    /// `savedSearches` is given; `cacheRoot` holds tiles and scans (`nil` keeps nothing). Tests pass
    /// their own so they leave the app's alone.
    static func open(_ url: URL, names: PlayerNames, savedSearches: SavedSearches? = nil, defaults: UserDefaults = .standard,
                     cacheRoot: URL? = TileCache.root) async throws -> WorldSession {
        let snapshot = try await WorldSnapshot.read(url)
        return WorldSession(snapshot: snapshot, names: names, savedSearches: savedSearches ?? SavedSearches(defaults: defaults),
                            defaults: defaults, cacheRoot: cacheRoot)
    }

    /// Stops rendering, watching and reading, remembers where the map was, and gives up file access.
    /// Call before replacing the session.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        watcher?.stop()
        refreshTasks.values.forEach { $0.cancel() }
        saveView()
        search.cancel()
        heatMap.cancel()
        playerRecords.close()
        map?.close()
        // Cancellation is a request, not completion. Retain access until even superseded work
        // has returned, including a region pass shared by several scans.
        let readers = Array(readers.values), search = search, heatMap = heatMap, playerRecords = playerRecords
        let map = map, retiring = Array(retiringMaps.values), refresh = Array(refreshTasks.values), access = access
        closingTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for reader in readers { group.addTask { await reader.close() } }
            }
            await search.waitForTasks()
            await heatMap.waitForReads()
            await playerRecords.waitForReads()
            await map?.waitForRenders()
            for task in retiring + refresh { await task.value }
            access.release()
        }
    }

    func waitUntilClosed() async { await closingTask?.value }

    // MARK: The map

    var selectedDimension: ChunkseeKit.Dimension? {
        dimensions.first { $0.id == selectedDimensionID }
    }

    var displayName: String { world.level.name ?? url.lastPathComponent }

    /// A dimension's name as players know it, by id.
    func dimensionName(_ id: String) -> String {
        dimensions.first { $0.id == id }?.displayName ?? id
    }

    /// The world spawn when it's in the selected dimension, otherwise the origin.
    var spawnPoint: CGPoint {
        guard let spawn = world.level.spawnPosition,
              (world.level.spawnDimension ?? "minecraft:overworld") == selectedDimensionID else { return .zero }
        return CGPoint(x: spawn.x, y: spawn.z)
    }

    /// Shows a location: switches to its dimension if needed, centers the map on it, and zooms in
    /// to at least 2×.
    func focus(on location: PlayerInfo.Location) {
        guard dimensions.contains(where: { $0.id == location.dimension }) else { return }
        selectedDimensionID = location.dimension
        map?.viewport.center = CGPoint(x: location.x, y: location.z)
        if let map, map.viewport.scale < 2 { map.viewport.scale = 2 }
    }

    /// Centers the map on a point in the selected dimension.
    func center(on point: CGPoint) {
        guard let id = selectedDimensionID else { return }
        focus(on: PlayerInfo.Location(dimension: id, x: point.x, y: 64, z: point.y))
    }

    /// Everything drawn over the selected dimension's terrain.
    var mapContent: MapContent {
        guard map != nil, let id = selectedDimensionID else { return MapContent() }
        let index = selectedIndex
        var content = MapContent()
        content.heatMap = heatMap.visibleImages ?? [:]
        if case .inGameMap(let item)? = selection, let image = image(for: item) {
            content.inGameMap = (item, image, inGameMapOpacity)
        }
        content.biomeAreas = index.biomeAreas.filter { visibility.biomes.contains($0.group) }
        content.biomes = index.biomes
        content.caveBiomes = index.caveBiomes
        content.border = details.borders[id].flatMap { $0.isLimited ? $0 : nil }
        content.showsGrid = visibility.showsGrid
        content.structures = index.structures.filter { visibility.structures.contains($0.group) }
        content.places = index.places.filter { visibility.places.contains($0.group) }
        content.creatures = index.creatures.filter { visibility.creatures.contains($0.group) }
        content.hits = pinnedHits.filter { $0.dimension == id && $0.position != nil }
        content.selectedHitID = search.selectedHitID
        content.players = PlayerPresentation.markers(for: players.filter { !visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                                     singleplayerUUID: world.level.singleplayerUUID,
                                                     worldDataVersion: world.level.dataVersion) { [names] in names.name(for: $0) }
        content.selection = selection
        return content
    }

    private func makeMapForSelection() {
        guard !isClosed else { return }
        if let old = map {
            old.close()
            let id = UUID()
            retiringMaps[id] = Task { [weak self] in
                await old.waitForRenders()
                self?.retiringMaps[id] = nil
            }
        }
        guard let dimension = selectedDimension else {
            map = nil
            return
        }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        map = MapModel(dimension: dimension, center: spawnPoint,
                       cacheDirectory: TileCache.directory(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot))
        if let viewport = views.viewport(for: dimension.id) { map?.viewport = viewport }
    }

    /// A click on the map: selects the portal or creature under it. A click elsewhere closes a
    /// portal's or creature's card, but not an in-game map laid over the terrain.
    func mapClicked(_ clicked: MapSelection?) {
        if clicked == nil, case .inGameMap? = selection { return }
        selection = clicked
    }

    /// Remembers where the map is, to reopen there. `dimensionID` is the dimension the map is
    /// showing: the selected one, except while switching away from it.
    func saveView(of dimensionID: String? = nil) {
        guard let map, let id = dimensionID ?? selectedDimensionID else { return }
        views.save(map.viewport, for: id, selected: selectedDimensionID)
    }

    /// The tile cache is limited to about 1 GB across all worlds; the least recently opened worlds'
    /// tiles go first, never the one being opened.
    private static func maintainTileCache(forWorldAt url: URL, root: URL?) {
        guard let root, let worldFolder = TileCache.worldFolder(forWorldAt: url, root: root) else { return }
        Task.detached(priority: .background) {
            TileCache.markUsed(worldFolder: worldFolder)
            TileCache.prune(root: root, limit: 1 << 30, keeping: worldFolder)
        }
    }

    // MARK: Search results, portals and in-game maps

    /// Centers the map on a search result, switching dimension if needed, and shows its layer's
    /// kind (a biome's outline, say) so the result is on the map.
    func show(_ hit: SearchHit) {
        guard let dimension = hit.dimension, let position = hit.position else { return }
        focus(on: PlayerInfo.Location(dimension: dimension, x: position.x, y: Double(hit.y ?? 64), z: position.y))
        search.selectedHitID = hit.id
        guard case .layer(let layer) = hit.source else { return }
        switch layer {
        case .structure(let group): visibility.structures.insert(group)
        case .place(let group): visibility.places.insert(group)
        case .creature(let group): visibility.creatures.insert(group)
        case .biome(let group): visibility.biomes.insert(group)
        }
    }

    /// What's pinned on the map: the search bar's results and those of the saved searches shown,
    /// each once.
    var pinnedHits: [SearchHit] {
        var seen = Set<SearchHit.ID>()
        let queries = [search.text] + savedSearches.all.filter(\.isShown).map(\.query)
        return queries.flatMap { search.results(for: $0) }.filter { seen.insert($0.id).inserted }
    }

    /// Saves the search bar's query to the sidebar.
    func saveSearch() {
        savedSearches.add(search.text)
    }

    /// Where a portal leads, or `nil` until both sides' portals are loaded.
    func link(for portal: NetherPortal) -> NetherPortal.Link? {
        guard let target = NetherPortal.targetDimension(from: portal.dimension),
              let candidates = portalsByDimension[target] else { return nil }
        return portal.link(into: candidates)
    }

    /// Whether a portal links both ways, one way, or to nothing.
    func linkStatus(for portal: NetherPortal) -> PortalLinkStatus? {
        PortalLinkStatus.status(of: portal, portals: portalsByDimension)
    }

    /// Selects a portal and centers the map on it, switching dimension if needed.
    func show(_ portal: NetherPortal) {
        focus(on: PlayerInfo.Location(dimension: portal.dimension, x: portal.centerX, y: Double(portal.minY), z: portal.centerZ))
        selection = .portal(portal)
    }

    /// Drawn maps made in the game, in dimensions this world has.
    var inGameMaps: [MapItem] {
        details.maps.filter { map in dimensions.contains { $0.id == map.dimension } }
    }

    /// A map's picture, made once and kept.
    func image(for map: MapItem) -> CGImage? {
        if let image = inGameMapImages[map.id] { return image }
        let image = InGameMapImage.make(map)
        inGameMapImages[map.id] = image
        return image
    }

    /// Draws an in-game map over the terrain and fits it in view, switching dimension if needed.
    func show(_ map: MapItem) {
        guard let dimension = map.dimension else { return }
        focus(on: PlayerInfo.Location(dimension: dimension, x: Double(map.centerX), y: 64, z: Double(map.centerZ)))
        self.map?.viewport.scale = InGameMapImage.fittingScale(for: map)
        selection = .inGameMap(map)
    }

    // MARK: Players

    func name(of player: PlayerInfo) -> String {
        PlayerPresentation.name(of: player, singleplayerUUID: world.level.singleplayerUUID, knownName: names.name(for: player.uuid))
    }

    /// A name for a player who may not have a file in this world, such as a pet's owner.
    func name(ofPlayerWith uuid: UUID) -> String {
        if let player = players.first(where: { $0.uuid == uuid }) { return name(of: player) }
        return names.name(for: uuid) ?? String(localized: "a player not in this world (\(uuid.uuidString.prefix(8).lowercased())…)")
    }

    /// Whether any player still has no real name.
    var hasUnnamedPlayers: Bool { players.contains { names.name(for: $0.uuid) == nil } }

    func isOutdated(_ player: PlayerInfo) -> Bool {
        PlayerPresentation.isOutdated(player, worldDataVersion: world.level.dataVersion)
    }

    // MARK: Live updates

    @ObservationIgnored private var watcher: WorldWatcher?
    /// Changes waiting for the game to finish saving.
    @ObservationIgnored private var pendingRegions: [String: Set<RegionCoordinate>] = [:]
    @ObservationIgnored private var pendingDimensions: Set<String> = []
    @ObservationIgnored private var pendingPlayers = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    /// How long to wait after the last change: an autosave writes many files over a second or two.
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)

    /// Notes which regions, dimensions and players changed, then refreshes once saving settles.
    func worldChanged(_ files: [URL]) {
        guard !isClosed else { return }
        for file in files.map(\.standardizedFileURL) {
            let path = file.path
            if path.hasPrefix(world.playerDataDirectory.standardizedFileURL.path + "/") {
                pendingPlayers = true
            } else if let dimension = dimensions.first(where: { path.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
                pendingDimensions.insert(dimension.id)
                if file.deletingLastPathComponent().path == dimension.regionDirectory.standardizedFileURL.path,
                   let region = RegionFile.parseCoordinates(file.lastPathComponent) {
                    pendingRegions[dimension.id, default: []].insert(RegionCoordinate(x: region.x, z: region.z))
                }
            }
        }
        guard !pendingDimensions.isEmpty || pendingPlayers else { return }
        refreshTask?.cancel()
        let delay = refreshDelay
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.refreshTasks[id] = nil }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
        refreshTask = task
        refreshTasks[id] = task
    }

    /// Waits for a refresh that's waiting or running.
    func waitForRefresh() async {
        await refreshTask?.value
    }

    private func refresh() async {
        let regions = pendingRegions, changedDimensions = pendingDimensions, playersChanged = pendingPlayers
        pendingRegions = [:]
        pendingDimensions = []
        pendingPlayers = false
        if let id = selectedDimensionID, changedDimensions.contains(id) {
            map?.regionsChanged(regions[id] ?? [])
            heatMap.load(reread: true)
        }
        if !changedDimensions.isEmpty {
            search.rebuild(firstDimension: selectedDimensionID)
        }
        if playersChanged {
            let world = world
            let updated = await Self.readPlayers(world)
            guard !Task.isCancelled, !isClosed else { return }
            players = updated
        }
    }

    @concurrent
    private nonisolated static func readPlayers(_ world: World) async -> [PlayerInfo] {
        world.players()
    }
}

enum WorldOpenError: LocalizedError, Equatable {
    case notAWorld
    case unreadable

    var errorDescription: String? {
        [failureReason, recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    // DocumentGroup supplies the alert's title and presents these bridged NSError fields.
    var failureReason: String? {
        switch self {
        case .notAWorld:
            String(localized: "That folder isn’t a Minecraft world.")
        case .unreadable:
            String(localized: "Chunksee couldn’t read this world.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAWorld:
            String(localized: "Choose a world’s folder inside your saves folder.")
        case .unreadable:
            String(localized: "It may be from a version Chunksee doesn’t support, or damaged.")
        }
    }
}

extension ChunkseeKit.Dimension {
    /// The dimension's name as players know it.
    var displayName: String {
        switch id {
        case "minecraft:overworld": String(localized: "Overworld")
        case "minecraft:the_nether": String(localized: "The Nether")
        case "minecraft:the_end": String(localized: "The End")
        default: id
        }
    }
}
