import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// One dimension document's controls, map and navigation. The world's shared resources own its
/// file access, index, players and live updates; closing one dimension leaves the others running.
@Observable
final class WorldSession {
    let viewID = UUID()
    let resources: WorldResources
    var url: URL { resources.url }
    var world: World { resources.world }
    var dimensions: [ChunkseeKit.Dimension] { resources.dimensions }
    var details: WorldDetails { resources.details }
    var names: PlayerNames { resources.names }
    var savedSearches: SavedSearches { resources.savedSearches }
    var savedPlaces: SavedPlaces { resources.savedPlaces }
    var players: [PlayerInfo] { resources.players }
    let visibility: LayerVisibility
    let search: SearchModel
    let heatMap: HeatMapLayer
    let slimeChunks: SlimeChunkLayer
    /// Created after initialization so feature models can refer weakly to this document.
    @ObservationIgnored private(set) lazy var routing = DimensionRouting(source: self)
    @ObservationIgnored private(set) lazy var selection = SelectionModel(source: self)

    let selectedDimensionID: String?
    let map: MapModel?
    var showsCoordinateSheet = false
    var placeDraft: SavedPlaceDraft?
    var ruler = MapRuler()
    let navigation: MapNavigation
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    var portalsByDimension: [String: [NetherPortal]] { search.portals }
    /// The selected dimension's part of the world index: what its sidebar lists and map show.
    var selectedIndex: DimensionIndex {
        selectedDimensionID.flatMap { search.index.dimensions[$0] } ?? DimensionIndex()
    }

    private var views: RememberedViews { resources.views }
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?

    convenience init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
                     defaults: UserDefaults, cacheRoot: URL?,
                     readRegion: @escaping RegionReader.Read = RegionReader.scan) {
        self.init(resources: WorldResources(snapshot: snapshot, names: names, savedSearches: savedSearches,
                                           defaults: defaults, cacheRoot: cacheRoot, readRegion: readRegion))
    }

    init(resources: WorldResources, dimensionID: String? = nil,
         renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
            = { try await $0.tile(for: $1) }) {
        self.resources = resources
        let selected = dimensionID ?? resources.defaultDimensionID
        visibility = LayerVisibility(world: resources.url, dimension: selected, defaults: resources.defaults)
        search = SearchModel(readers: [], work: resources.backgroundWork, playerRoster: resources.playerRoster, names: resources.names,
                             singleplayerUUID: resources.world.level.singleplayerUUID, firstDimension: selected,
                             savedSearches: resources.savedSearches, indexStore: resources.index)
        heatMap = HeatMapLayer(reader: selected.flatMap { resources.readers[$0] }, work: resources.backgroundWork)
        selectedDimensionID = selected
        let initialMap = Self.initialMap(resources: resources, dimensionID: selected, renderTile: renderTile)
        map = initialMap
        navigation = MapNavigation(map: initialMap)
        slimeChunks = SlimeChunkLayer(dimensionID: selected, seed: resources.details.seed,
                                     regions: initialMap?.availableRegions ?? [], work: resources.backgroundWork)
        heatMap.restoreVisibility(from: visibility)
        slimeChunks.restoreVisibility(from: visibility)
        resources.attach(self)
    }

    /// Opens a world folder. `url` must come from the Open panel or a resolved bookmark.
    /// `defaults` keeps which layers are shown and where the map was, and saved searches unless
    /// `savedSearches` is given; `cacheRoot` holds tiles and scans (`nil` keeps nothing). Tests pass
    /// their own so they leave the app's alone.
    static func open(_ url: URL, names: PlayerNames, savedSearches: SavedSearches? = nil, defaults: UserDefaults,
                     cacheRoot: URL?) async throws -> WorldSession {
        let snapshot = try await WorldSnapshot.read(url)
        return WorldSession(snapshot: snapshot, names: names, savedSearches: savedSearches ?? SavedSearches(defaults: defaults),
                            defaults: defaults, cacheRoot: cacheRoot)
    }

    /// Closing drains this dimension's reads; the world's shared reads stay alive for the others.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        saveView()
        search.cancel()
        heatMap.cancel()
        slimeChunks.cancel()
        selection.close()
        map?.close()
        let search = search, heatMap = heatMap, slimeChunks = slimeChunks, selection = selection
        let map = map
        let task = Task {
            await search.waitForTasks()
            await heatMap.waitForReads()
            await slimeChunks.waitForImages()
            await selection.waitForReads()
            await map?.waitForRenders()
        }
        closingTask = task
        resources.detach(self)
    }

    func waitUntilClosed() async {
        await closingTask?.value
        if resources.isClosed { await resources.waitUntilClosed() }
    }

    // MARK: The map

    var selectedDimension: ChunkseeKit.Dimension? {
        dimensions.first { $0.id == selectedDimensionID }
    }

    var displayName: String { world.level.name ?? url.lastPathComponent }

    /// Whether the selected dimension can't be drawn because it was saved before Minecraft 1.18, in the
    /// format ChunkseeKit doesn't read: the whole world was last saved before then (its level data
    /// predates `DataVersion.flatChunkRoot`), or, once read, every saved chunk here is still in the old
    /// format, as in a world opened in a newer Minecraft without updating its unvisited chunks.
    /// A dimension with some readable chunks shows those.
    var isSavedBeforeReadableFormat: Bool {
        (world.level.dataVersion ?? 0) < DataVersion.flatChunkRoot || selectedIndex.formats.isOnlyLegacy
    }

    /// The biome groups the selected dimension can have, once its part of the index is read; none
    /// before then, or for a world Chunksee can't read, so the sidebar doesn't list biomes as missing.
    var possibleBiomes: [BiomeGroup] {
        // A world saved before 1.18 can't be read, so "0" would wrongly say a biome isn't there.
        guard !isSavedBeforeReadableFormat, let dimension = selectedDimension, search.index.dimensions[dimension.id] != nil else { return [] }
        return dimension.vanillaBiomes.map(BiomeGroup.init(id:))
    }

    /// A dimension's name as players know it, by id.
    func dimensionName(_ id: String) -> String {
        let name = Self.dimensionName(id)
        let isAmbiguous = dimensions.contains { $0.id != id && Self.dimensionName($0.id) == name }
        return isAmbiguous ? String(localized: "\(name) (\(id))") : name
    }

    private static func dimensionName(_ id: String) -> String {
        switch id {
        case "minecraft:overworld": String(localized: "Overworld")
        case "minecraft:the_nether": String(localized: "The Nether")
        case "minecraft:the_end": String(localized: "The End")
        default: ReadableName.from(id)
        }
    }

    /// The world spawn when it's in the selected dimension, otherwise the origin.
    var spawnPoint: CGPoint {
        Self.spawnPoint(in: world, dimensionID: selectedDimensionID)
    }

    private static func spawnPoint(in world: World, dimensionID: String?) -> CGPoint {
        guard let spawn = world.level.spawnPosition,
              world.level.spawnDimension == dimensionID else { return .zero }
        return MapCoordinates.center(of: CGPoint(x: spawn.x, y: spawn.z))
    }

    /// Shows a location in its dimension document, centers the map, and zooms in
    /// to at least 2×, unless `keepingZoom`, as choosing from the sidebar does (Ryan, 2026-10-13).
    func focus(on location: PlayerInfo.Location, blockPosition: Bool = false, keepingZoom: Bool = false) {
        guard dimensions.contains(where: { $0.id == location.dimension }),
              Coordinates.canLocate(x: location.x, y: location.y, z: location.z) else { return }
        if routing.route(to: location.dimension, perform: { $0.focus(on: location, blockPosition: blockPosition, keepingZoom: keepingZoom) }) { return }
        navigation.focus(on: CGPoint(x: location.x, y: location.z), blockPosition: blockPosition, keepingZoom: keepingZoom)
    }

    /// Centers the map on a point in the selected dimension.
    func center(on point: CGPoint, keepingZoom: Bool = false) {
        guard let id = selectedDimensionID else { return }
        focus(on: PlayerInfo.Location(dimension: id, x: point.x, y: 64, z: point.y), keepingZoom: keepingZoom)
    }

    func savePlace(at point: CGPoint? = nil, in dimension: String? = nil) {
        guard !isClosed, let point = point ?? map?.viewport.center,
              let coordinates = MapCoordinates(point: point), let dimension = dimension ?? selectedDimensionID else { return }
        placeDraft = SavedPlaceDraft(name: "", dimension: dimension, position: coordinates.position)
    }

    func edit(_ place: SavedPlace) {
        guard !isClosed else { return }
        placeDraft = SavedPlaceDraft(existingID: place.id, name: place.name, dimension: place.dimension, position: place.position)
    }

    func canVisit(_ place: SavedPlace) -> Bool { dimensions.contains { $0.id == place.dimension } }

    func visit(_ place: SavedPlace) {
        guard canVisit(place) else { return }
        if routing.route(to: place.dimension, perform: { $0.visit(place) }) { return }
        navigation.goToCoordinates(place.position)
    }

    func setRulerEnabled(_ enabled: Bool) {
        ruler.isEnabled = enabled
        if enabled, selection.mapSelection != nil { selection.inspector = nil }
    }

    func beginMeasurement(at point: CGPoint, in dimension: String) {
        guard !isClosed, selectedDimensionID == dimension else { return }
        setRulerEnabled(true)
        ruler.clear()
        ruler.mark(point)
    }

    /// A native document reread or move replaces readers, while keeping window navigation.
    func restoreView(from previous: WorldSession) {
        guard !isClosed, selectedDimensionID == previous.selectedDimensionID, map != nil, previous.map != nil else { return }
        navigation.restore(from: previous.navigation)
        ruler = previous.ruler
    }

    /// Everything drawn over the selected dimension's terrain.
    var mapContent: MapContent {
        guard map != nil, let id = selectedDimensionID else { return MapContent() }
        let index = selectedIndex
        var content = MapContent()
        content.heatMap = heatMap.visibleImages ?? [:]
        content.slimeChunks = slimeChunks.visibleImages
        content.slimeSeed = slimeChunks.visibleSeed
        if case .inGameMap(let item)? = selection.mapSelection, let image = selection.image(for: item) {
            content.inGameMap = (item, image, selection.inGameMapOpacity)
        }
        content.biomeAreas = index.biomeAreas.filter { visibility.biomes.contains($0.group) }
        content.biomes = index.biomes
        content.caveBiomes = index.caveBiomes
        content.border = details.borders[id].flatMap { $0.isLimited ? $0 : nil }
        content.showsGrid = visibility.showsGrid
        content.structures = index.structures.filter { visibility.structures.contains($0.group) }
        content.placePoints = index.placePoints
        content.shownPlaceGroups = visibility.places
        content.creaturePoints = index.creaturePoints
        content.shownCreatureGroups = visibility.creatures
        content.hits = pinnedHits.filter { $0.dimension == id && $0.position != nil }
        content.selectedHitID = selection.selectedHitID
        content.players = drawnPlayerMarkers
        content.selection = selection.mapSelection
        content.selectedItem = selection.sidebarSelection
        content.selectedPlayerID = if case .player(let uuid)? = selection.inspector { uuid } else { nil }
        content.savedPlaces = savedPlaces.all.filter { $0.dimension == id }
        content.ruler = ruler
        return content
    }

    private static func initialMap(resources: WorldResources, dimensionID: String?,
                                   renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?) -> MapModel? {
        guard let dimension = resources.dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        let map = MapModel(work: resources.backgroundWork, dimension: dimension, center: spawnPoint(in: resources.world, dimensionID: dimensionID),
                           cacheDirectory: TileCache.directory(forWorldAt: resources.url, dimensionID: dimension.id, root: resources.cacheRoot),
                           renderTile: renderTile)
        if let viewport = resources.views.viewport(for: dimension.id) { map.viewport = viewport }
        map.setDepth(resources.views.depth(for: dimension.id))
        return map
    }

    var drawnPlayerMarkers: [MapMarker] {
        guard map != nil, let id = selectedDimensionID else { return [] }
        return PlayerPresentation.markers(for: players.filter { !visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                          singleplayerUUID: world.level.singleplayerUUID,
                                          worldDataVersion: world.level.dataVersion) { [names] in names.name(for: $0) }
    }

    /// Whether choosing a player's row can center the map on their current position.
    func canFocus(_ player: PlayerInfo) -> Bool {
        guard let position = PlayerPresentation.position(of: player) else { return false }
        return dimensions.contains { $0.id == position.dimension }
    }

    /// The native front dimension can change without this session switching dimensions.
    func becameActive(isTerminating: Bool = false) {
        guard !isTerminating, !isClosed, !resources.isClosed, let id = selectedDimensionID, map != nil else { return }
        resources.activeDimensionID = id
        saveView()
    }

    /// Remembers where the map is, to reopen there. `dimensionID` is the dimension the map is
    /// showing: the selected one, except while switching away from it.
    func saveView() {
        guard let map, let id = selectedDimensionID else { return }
        views.save(map.viewport, for: id, selected: resources.activeDimensionID, depth: map.depth)
    }

    // MARK: Search results, portals and in-game maps

    /// The sidebar, map pins and click resolver share the same per-dimension 200-row limit.
    func listedHits(for query: String) -> (rows: ArraySlice<SearchHit>, total: Int) {
        let hits = listed(search.results(for: query))
        return (hits.prefix(200), hits.count)
    }

    var visibleSearchQueries: [String] {
        (search.isActive ? [search.text] : []) + savedSearches.all.filter(\.isShown).map(\.query)
    }

    var pinnedHits: [SearchHit] {
        var seen = Set<SearchHit.ID>()
        return visibleSearchQueries.flatMap { listedHits(for: $0).rows }.filter { seen.insert($0.id).inserted }
    }

    var canSaveSearch: Bool {
        let query = search.text.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && !savedSearches.contains(query)
    }

    /// Saves the search bar's query to the sidebar.
    func saveSearch() {
        savedSearches.add(search.text)
    }

    /// Where a portal leads, or `nil` while its target's saved portals are pending or unavailable.
    func link(for portal: NetherPortal) -> NetherPortal.Link? {
        guard let target = NetherPortal.targetDimension(from: portal.dimension),
              let candidates = portalsByDimension[target] else { return nil }
        return portal.link(into: candidates)
    }

    func isWaitingForPortalLink(_ portal: NetherPortal) -> Bool {
        guard !isClosed, let target = NetherPortal.targetDimension(from: portal.dimension) else { return false }
        return resources.index.isWaitingForPortals(in: target)
    }

    /// Whether a portal links both ways, one way, or to nothing.
    func linkStatus(for portal: NetherPortal) -> PortalLinkStatus? {
        PortalLinkStatus.status(of: portal, portals: portalsByDimension)
    }

    /// Drawn maps made in the game that this dimension's sidebar lists: those drawn in it, and, in
    /// the first dimension, those from a dimension this world doesn't have, by the shared rule.
    var inGameMaps: [MapItem] {
        details.maps.filter { lists($0.dimension) }
    }

    /// Whether a map was drawn in a dimension this world has, so it can be shown on the map.
    func canShow(_ map: MapItem) -> Bool {
        dimensions.contains { $0.id == map.dimension }
    }

    // MARK: Players

    func name(of player: PlayerInfo) -> String {
        PlayerPresentation.name(of: player, singleplayerUUID: world.level.singleplayerUUID, knownName: names.name(for: player.uuid))
    }

    /// A name for a player who may not have a file in this world, such as a pet's owner.
    func name(ofPlayerWith uuid: UUID) -> String {
        if let player = players.first(where: { $0.uuid == uuid }) { return name(of: player) }
        return PlayerPresentation.absentPlayerName(uuid, knownName: names.name(for: uuid))
    }

    /// Whether this dimension's sidebar lists something in `dimension`. Each dimension lists only
    /// what's in it (Ryan, 2026-10-13); something with no dimension in this world, such as an item
    /// in a player's inventory, is listed with the first dimension, the Overworld.
    func lists(_ dimension: String?) -> Bool {
        guard let id = selectedDimensionID else { return false }
        if let dimension, dimensions.contains(where: { $0.id == dimension }) { return dimension == id }
        return id == dimensions.first?.id
    }

    /// The saved places this dimension's sidebar lists.
    var listedPlaces: [SavedPlace] { savedPlaces.all.filter { lists($0.dimension) } }

    /// A search's results that this dimension's sidebar lists.
    func listed(_ hits: [SearchHit]) -> [SearchHit] { hits.filter { lists($0.dimension) } }

    /// The players this dimension's sidebar lists.
    var listedPlayers: [PlayerInfo] {
        players.filter { lists(PlayerPresentation.position(of: $0)?.dimension) }
    }

    /// Whether any player still has no real name.
    var hasUnnamedPlayers: Bool { players.contains { names.name(for: $0.uuid) == nil } }

    func isOutdated(_ player: PlayerInfo) -> Bool {
        PlayerPresentation.isOutdated(player, worldDataVersion: world.level.dataVersion)
    }

    // MARK: Live updates shared by every dimension

    var refreshDelay: Duration {
        get { resources.refreshDelay }
        set { resources.refreshDelay = newValue }
    }
    func worldChanged(_ files: [URL]) { resources.worldChanged(files) }
    func waitForRefresh() async { await resources.waitForRefresh() }

}

enum WorldOpenError: LocalizedError, Equatable {
    case notAWorld
    case notADimension
    case needsWorldFolder
    case unreadable

    var errorDescription: String? {
        [failureReason, recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    // Native document error presentation uses these bridged NSError fields.
    var failureReason: String? {
        switch self {
        case .notAWorld, .notADimension:
            String(localized: "That folder isn’t a Minecraft world.")
        case .needsWorldFolder:
            String(localized: "Chunksee can’t see the world this dimension belongs to.")
        case .unreadable:
            String(localized: "Chunksee couldn’t read this world.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAWorld, .notADimension:
            String(localized: "Choose a world’s folder inside your saves folder.")
        case .needsWorldFolder:
            String(localized: "Open the world’s folder, inside your saves folder, instead.")
        case .unreadable:
            String(localized: "It may be from a version Chunksee doesn’t support, or damaged.")
        }
    }
}
