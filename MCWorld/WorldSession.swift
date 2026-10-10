import CoreGraphics
import Foundation
import MCWorldKit
import Observation

/// The world the user opened, and the security-scoped access that lets the sandboxed app read it.
/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
    case player(UUID)
}

@Observable
final class WorldSession {
    let url: URL
    let world: World
    let dimensions: [MCWorldKit.Dimension]
    var selectedDimensionID: String? {
        didSet {
            guard oldValue != selectedDimensionID else { return }
            if selectedPortal?.dimension != selectedDimensionID { selectedPortal = nil }
            if selectedCreature?.dimension != selectedDimensionID { selectedCreature = nil }
            if visibleInGameMap == nil { selectedInGameMapID = nil }
            loadHeatMap()
            makeMapForSelection()
        }
    }
    private(set) var map: MapModel?
    /// Players with saved data, most recently saved first.
    let players: [PlayerInfo]
    var showsPlayers = true
    /// What the inspector shows, if it's open.
    var inspector: Inspector?
    /// Game rules, weather, borders and the like, read when the world opens.
    let details: WorldDetails
    /// Structure groups shown on the map; remembered between launches.
    var shownStructureGroups: Set<StructureGroup> {
        didSet {
            defaults.set(shownStructureGroups.map(\.rawValue).sorted(), forKey: Self.shownStructuresKey)
        }
    }
    private static let shownStructuresKey = "shownStructureGroups"
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    private(set) var portalsByDimension: [String: [NetherPortal]] = [:]
    /// The portal whose details card is showing.
    var selectedPortal: NetherPortal? {
        didSet { if selectedPortal != nil { selectedInGameMapID = nil; selectedCreature = nil } }
    }
    /// The creature whose card is showing.
    var selectedCreature: CreatureMarker? {
        didSet { if selectedCreature != nil { selectedPortal = nil; selectedInGameMapID = nil } }
    }

    // MARK: Search

    /// The toolbar search text. Searching builds the index of containers and signs the first time.
    var searchText = "" {
        didSet { if searchText != oldValue { updateSearch() } }
    }
    private(set) var searchResults: [SearchHit] = []
    private(set) var isIndexing = false
    /// The result the map is centered on, highlighted among the result markers.
    var selectedHitID: SearchHit.ID?
    private var searchIndex: SearchIndex?
    private var indexTask: Task<Void, Never>?

    private func updateSearch() {
        selectedHitID = nil
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        guard let index = searchIndex else {
            buildIndex()
            return
        }
        let names = names, level = world.level
        searchResults = WorldSearch.search(searchText, in: index, players: players) {
            PlayerPresentation.name(of: $0, singleplayerUUID: level.singleplayerUUID, knownName: names.name(for: $0.uuid))
        }
    }

    /// Reads every container, sign and named creature in every dimension in the background, once
    /// per session. It starts when the world opens, so the index is usually ready before the first
    /// search; drawing the map comes first, hence utility priority.
    private func buildIndex() {
        guard indexTask == nil else { return }
        isIndexing = true
        let dimensions = dimensions
        indexTask = Task(priority: .utility) { [weak self] in
            let index = await WorldSearch.index(dimensions)
            guard let self, !Task.isCancelled else { return }
            self.searchIndex = index
            self.isIndexing = false
            self.updateSearch()
        }
    }

    /// Waits for the search index, if one is being built.
    func waitForIndex() async {
        await indexTask?.value
    }

    // MARK: Time-spent heat map

    /// Whether the heat map is drawn over the terrain. Turning it on reads the dimension's chunk
    /// times the first time.
    var showsHeatMap = false {
        didSet { loadHeatMap() }
    }
    /// Heat images by dimension id, then region.
    private(set) var heatMaps: [String: [RegionCoordinate: CGImage]] = [:]
    @ObservationIgnored private var heatMapTasks: [String: Task<Void, Never>] = [:]

    /// The selected dimension's heat map, when shown and read.
    var visibleHeatMap: [RegionCoordinate: CGImage]? {
        guard showsHeatMap, let id = selectedDimensionID else { return nil }
        return heatMaps[id]
    }

    var isLoadingHeatMap: Bool {
        showsHeatMap && selectedDimensionID.map { heatMaps[$0] == nil } ?? false
    }

    private func loadHeatMap() {
        guard showsHeatMap, let dimension = selectedDimension, heatMaps[dimension.id] == nil,
              heatMapTasks[dimension.id] == nil else { return }
        heatMapTasks[dimension.id] = Task(priority: .userInitiated) { [weak self] in
            let images = await HeatMap.images(for: dimension)
            guard let self, !Task.isCancelled else { return }
            self.heatMaps[dimension.id] = images
        }
    }

    /// Waits for heat maps being read.
    func waitForHeatMaps() async {
        for task in heatMapTasks.values { await task.value }
    }

    // MARK: In-game maps

    /// Drawn maps made in the game, in dimensions this world has.
    var inGameMaps: [MapItem] {
        details.maps.filter { map in dimensions.contains { $0.id == map.dimension } }
    }
    /// The in-game map drawn over the terrain, if any.
    var selectedInGameMapID: Int? {
        didSet { if selectedInGameMapID != nil { selectedPortal = nil; selectedCreature = nil } }
    }
    /// How opaque the in-game map is over the terrain.
    var inGameMapOpacity = 0.85
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]

    /// The selected in-game map, when it's in the dimension being shown.
    var visibleInGameMap: MapItem? {
        details.maps.first { $0.id == selectedInGameMapID && $0.dimension == selectedDimensionID }
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
        selectedInGameMapID = map.id
    }

    /// The selected dimension's world border, when it's closer than Minecraft's default.
    var visibleBorder: WorldBorder? {
        selectedDimensionID.flatMap { details.borders[$0] }.flatMap { $0.isLimited ? $0 : nil }
    }

    /// Search results in the selected dimension, for map markers.
    var visibleHits: [SearchHit] {
        searchResults.filter { $0.dimension == selectedDimensionID && $0.position != nil }
    }

    /// Centers the map on a result, switching dimension if needed.
    func show(_ hit: SearchHit) {
        guard let dimension = hit.dimension, let position = hit.position else { return }
        focus(on: PlayerInfo.Location(dimension: dimension, x: position.x, y: Double(hit.y ?? 64), z: position.y))
        selectedHitID = hit.id
    }

    /// Point-of-interest groups shown on the map; remembered between launches.
    var shownPlaceGroups: Set<PlaceGroup> {
        didSet { defaults.set(shownPlaceGroups.map(\.rawValue).sorted(), forKey: Self.shownPlacesKey) }
    }
    private static let shownPlacesKey = "shownPlaceGroups"
    /// Creature groups shown on the map; remembered between launches.
    var shownCreatureGroups: Set<CreatureGroup> {
        didSet { defaults.set(shownCreatureGroups.map(\.rawValue).sorted(), forKey: Self.shownCreaturesKey) }
    }
    private static let shownCreaturesKey = "shownCreatureGroups"
    /// Biomes outlined on the map; remembered between launches. None at first: outlining every
    /// biome would cover the map.
    var shownBiomeGroups: Set<BiomeGroup> {
        didSet { defaults.set(shownBiomeGroups.map(\.id).sorted(), forKey: Self.shownBiomesKey) }
    }
    private static let shownBiomesKey = "shownBiomeGroups"
    /// App-wide player names, shared across worlds.
    let names: PlayerNames

    private let isAccessingSecurityScope: Bool
    private let defaults: UserDefaults

    private init(url: URL, world: World, players: [PlayerInfo], details: WorldDetails, names: PlayerNames, defaults: UserDefaults,
                 isAccessingSecurityScope: Bool) {
        self.defaults = defaults
        self.url = url
        self.details = details
        self.names = names
        if let saved = defaults.stringArray(forKey: Self.shownStructuresKey) {
            shownStructureGroups = Set(saved.compactMap(StructureGroup.init(rawValue:)))
        } else {
            shownStructureGroups = Set(StructureGroup.allCases.filter(\.isShownByDefault))
        }
        if let saved = defaults.stringArray(forKey: Self.shownPlacesKey) {
            shownPlaceGroups = Set(saved.compactMap(PlaceGroup.init(rawValue:)))
        } else {
            shownPlaceGroups = Set(PlaceGroup.allCases.filter(\.isShownByDefault))
        }
        if let saved = defaults.stringArray(forKey: Self.shownCreaturesKey) {
            shownCreatureGroups = Set(saved.compactMap(CreatureGroup.init(rawValue:)))
        } else {
            shownCreatureGroups = Set(CreatureGroup.allCases.filter(\.isShownByDefault))
        }
        shownBiomeGroups = Set((defaults.stringArray(forKey: Self.shownBiomesKey) ?? []).map(BiomeGroup.init(id:)))
        self.world = world
        self.players = players
        self.dimensions = world.dimensions()
        self.isAccessingSecurityScope = isAccessingSecurityScope
        self.selectedDimensionID = dimensions.first?.id
        makeMapForSelection()
        Self.maintainTileCache(forWorldAt: url)
        loadPortals()
        buildIndex()
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
        selectedPortal = portal
    }

    /// The tile cache is limited to about 1 GB across all worlds; the least recently opened worlds'
    /// tiles go first, never the one being opened.
    private static func maintainTileCache(forWorldAt url: URL) {
        guard let root = TileCache.root, let worldFolder = TileCache.worldFolder(forWorldAt: url) else { return }
        Task.detached(priority: .background) {
            TileCache.markUsed(worldFolder: worldFolder)
            TileCache.prune(root: root, limit: 1 << 30, keeping: worldFolder)
        }
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    /// `defaults` keeps which layers are shown; tests pass their own so they leave the app's alone.
    static func open(_ url: URL, names: PlayerNames, defaults: UserDefaults = .standard) async throws -> WorldSession {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let (world, players, details) = try await load(url)
            return WorldSession(url: url, world: world, players: players, details: details, names: names, defaults: defaults,
                                isAccessingSecurityScope: accessing)
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

    var displayName: String { world.level.name ?? url.lastPathComponent }

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

    /// Player, death and respawn markers for the selected dimension, when players are shown.
    var markers: [MapMarker] {
        guard showsPlayers, let id = selectedDimensionID else { return [] }
        let names = names
        return PlayerPresentation.markers(for: players, in: id, singleplayerUUID: world.level.singleplayerUUID,
                                          worldDataVersion: world.level.dataVersion, knownName: { names.name(for: $0) })
    }

    /// Structures of the shown groups in the selected dimension.
    var visibleStructures: [StructureMarker] {
        (map?.structures ?? []).filter { shownStructureGroups.contains($0.group) }
    }

    /// Points of interest of the shown groups in the selected dimension.
    var visibleCreatures: [CreatureMarker] {
        (map?.creatures ?? []).filter { shownCreatureGroups.contains($0.group) }
    }

    var visibleBiomeAreas: [BiomeArea] {
        (map?.biomeAreas ?? []).filter { shownBiomeGroups.contains($0.group) }
    }

    var visiblePlaces: [PlaceMarker] {
        (map?.places ?? []).filter { shownPlaceGroups.contains($0.group) }
    }

    /// Shows a location: switches to its dimension if needed and centers the map on it.
    /// The world spawn when it's in the selected dimension, otherwise the origin.
    var spawnPoint: CGPoint {
        guard let spawn = world.level.spawnPosition,
              (world.level.spawnDimension ?? "minecraft:overworld") == selectedDimensionID else { return .zero }
        return CGPoint(x: spawn.x, y: spawn.z)
    }

    /// Centers the map on a point in the selected dimension.
    func center(on point: CGPoint) {
        guard let id = selectedDimensionID else { return }
        focus(on: PlayerInfo.Location(dimension: id, x: point.x, y: 64, z: point.y))
    }

    func focus(on location: PlayerInfo.Location) {
        guard dimensions.contains(where: { $0.id == location.dimension }) else { return }
        selectedDimensionID = location.dimension
        map?.viewport.center = CGPoint(x: location.x, y: location.z)
        if let map, map.viewport.scale < 2 { map.viewport.scale = 2 }
    }

    var selectedDimension: MCWorldKit.Dimension? {
        dimensions.first { $0.id == selectedDimensionID }
    }

    private func makeMapForSelection() {
        map?.cancel()
        guard let dimension = selectedDimension else {
            map = nil
            return
        }
        // Start at the world spawn when it's in this dimension, otherwise at the origin.
        map = MapModel(dimension: dimension, center: spawnPoint,
                       cacheDirectory: TileCache.directory(forWorldAt: url, dimensionID: dimension.id))
        map?.loadStructures()
        map?.loadPlaces()
        map?.loadCreatures()
        map?.loadBiomeAreas()
    }

    /// Stops rendering and gives up file access. Call before replacing the session.
    func close() {
        indexTask?.cancel()
        heatMapTasks.values.forEach { $0.cancel() }
        map?.cancel()
        if isAccessingSecurityScope { url.stopAccessingSecurityScopedResource() }
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
