import CoreGraphics
import Foundation
import MCWorldKit
import Observation

/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
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
    let dimensions: [MCWorldKit.Dimension]
    /// Game rules, weather, borders, in-game maps and the like, read when the world opens.
    let details: WorldDetails
    /// App-wide player names, shared across worlds.
    let names: PlayerNames
    let visibility: LayerVisibility
    let search: SearchModel
    let heatMap: HeatMapLayer

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
    var inspector: Inspector?
    var selection: MapSelection?
    /// How opaque a selected in-game map is over the terrain.
    var inGameMapOpacity = 0.85
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    private(set) var portalsByDimension: [String: [NetherPortal]] = [:]

    private let cacheRoot: URL?
    /// One per dimension: reads each region once for the map's layers, search and the heat map.
    private let readers: [String: RegionReader]
    private let views: RememberedViews
    private let isAccessingSecurityScope: Bool
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]

    private init(url: URL, world: World, players: [PlayerInfo], details: WorldDetails, names: PlayerNames, defaults: UserDefaults,
                 cacheRoot: URL?, isAccessingSecurityScope: Bool) {
        let dimensions = world.dimensions()
        let readers = Dictionary(uniqueKeysWithValues: dimensions.map { dimension in
            (dimension.id, RegionReader(dimension: dimension, cache: ScanCache(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot)))
        })
        self.url = url
        self.world = world
        self.dimensions = dimensions
        self.details = details
        self.names = names
        self.players = players
        self.cacheRoot = cacheRoot
        self.readers = readers
        self.views = RememberedViews(world: url, defaults: defaults)
        self.isAccessingSecurityScope = isAccessingSecurityScope
        self.visibility = LayerVisibility(defaults: defaults)
        self.search = SearchModel(readers: dimensions.compactMap { readers[$0.id] }, players: players, names: names,
                                  singleplayerUUID: world.level.singleplayerUUID)
        self.heatMap = HeatMapLayer(readers: readers)
        // Reopen in the dimension last viewed, if it still exists.
        let last = views.lastDimension.flatMap { id in dimensions.first { $0.id == id }?.id }
        self.selectedDimensionID = last ?? dimensions.first?.id
        heatMap.dimension = selectedDimensionID
        makeMapForSelection()
        Self.maintainTileCache(forWorldAt: url, root: cacheRoot)
        loadPortals()
        watcher = WorldWatcher(folder: url) { [weak self] files in self?.worldChanged(files) }
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    /// `defaults` keeps which layers are shown and where the map was; `cacheRoot` holds tiles and
    /// scans (`nil` keeps nothing). Tests pass their own so they leave the app's alone.
    static func open(_ url: URL, names: PlayerNames, defaults: UserDefaults = .standard,
                     cacheRoot: URL? = TileCache.root) async throws -> WorldSession {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let (world, players, details) = try await load(url)
            return WorldSession(url: url, world: world, players: players, details: details, names: names, defaults: defaults,
                                cacheRoot: cacheRoot, isAccessingSecurityScope: accessing)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Reading `level.dat`, listing dimensions and reading player and settings files touches the
    /// disk, so it runs off the main actor.
    @concurrent
    private nonisolated static func load(_ url: URL) async throws -> (World, [PlayerInfo], WorldDetails) {
        do {
            let world = try World(contentsOf: url)
            return (world, world.players(), WorldDetails.read(world))
        } catch WorldError.missingLevelDat {
            throw WorldOpenError.notAWorld
        } catch {
            throw WorldOpenError.unreadable
        }
    }

    /// Stops rendering, watching and reading, remembers where the map was, and gives up file access.
    /// Call before replacing the session.
    func close() {
        watcher?.stop()
        refreshTask?.cancel()
        saveView()
        search.cancel()
        heatMap.cancel()
        map?.cancel()
        if isAccessingSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: The map

    var selectedDimension: MCWorldKit.Dimension? {
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
        guard let map, let id = selectedDimensionID else { return MapContent() }
        var content = MapContent()
        content.heatMap = heatMap.visibleImages ?? [:]
        if case .inGameMap(let item)? = selection, let image = image(for: item) {
            content.inGameMap = (item, image, inGameMapOpacity)
        }
        content.biomeAreas = map.biomeAreas.filter { visibility.biomes.contains($0.group) }
        content.border = details.borders[id].flatMap { $0.isLimited ? $0 : nil }
        content.structures = map.structures.filter { visibility.structures.contains($0.group) }
        content.places = map.places.filter { visibility.places.contains($0.group) }
        content.creatures = map.creatures.filter { visibility.creatures.contains($0.group) }
        content.hits = search.results.filter { $0.dimension == id && $0.position != nil }
        content.selectedHitID = search.selectedHitID
        content.players = PlayerPresentation.markers(for: players.filter { !visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                                     singleplayerUUID: world.level.singleplayerUUID,
                                                     worldDataVersion: world.level.dataVersion) { [names] in names.name(for: $0) }
        content.selection = selection
        return content
    }

    private func makeMapForSelection() {
        map?.cancel()
        guard let dimension = selectedDimension else {
            map = nil
            return
        }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        map = MapModel(dimension: dimension, center: spawnPoint,
                       cacheDirectory: TileCache.directory(forWorldAt: url, dimensionID: dimension.id, root: cacheRoot),
                       reader: readers[dimension.id])
        if let viewport = views.viewport(for: dimension.id) { map?.viewport = viewport }
        map?.loadLayers()
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

    /// Reads both dimensions' portals in the background; links need the other side's portals.
    private func loadPortals() {
        let dimensions = dimensions.filter { NetherPortal.targetDimension(from: $0.id) != nil }
        Task(priority: .utility) { [weak self] in
            let found = await Self.readPortals(dimensions)
            self?.portalsByDimension = found
        }
    }

    @concurrent
    private nonisolated static func readPortals(_ dimensions: [MCWorldKit.Dimension]) async -> [String: [NetherPortal]] {
        var result: [String: [NetherPortal]] = [:]
        for dimension in dimensions { result[dimension.id] = (try? dimension.netherPortals()) ?? [] }
        return result
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
    /// How long to wait after the last change: an autosave writes many files over a second or two.
    @ObservationIgnored var refreshDelay: Duration = .seconds(2)

    /// Notes which regions, dimensions and players changed, then refreshes once saving settles.
    func worldChanged(_ files: [URL]) {
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
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
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
            map?.reloadLayers()
            heatMap.load(reread: true)
        }
        if !changedDimensions.isEmpty {
            loadPortals()
            search.rebuild()
        }
        if playersChanged {
            let world = world
            players = await Self.readPlayers(world)
        }
    }

    @concurrent
    private nonisolated static func readPlayers(_ world: World) async -> [PlayerInfo] {
        world.players()
    }
}

enum WorldOpenError: LocalizedError {
    case notAWorld
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notAWorld:
            String(localized: "That folder isn’t a Minecraft world. Choose a world’s folder inside your saves folder.")
        case .unreadable:
            String(localized: "MCWorld couldn’t read this world. It may be from a version MCWorld doesn’t support, or damaged.")
        }
    }
}

extension MCWorldKit.Dimension {
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
