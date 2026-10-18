import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
    case storage
    case player(UUID)
    /// The portal, creature or in-game map selected on the map.
    case selection
}

/// A sidebar row that can be selected. Choosing it shows its item: World Info and Storage in the
/// inspector, everything else on the map.
enum SidebarItem: Hashable {
    case worldInfo
    case storage
    case savedPlace(UUID)
    case structure(String)
    case place(String)
    case creature(String)
    case biome(String)
    case inGameMap(Int)
    case player(UUID)
    /// A search result, under the query that found it: the search bar's or a saved search's.
    case hit(query: String, id: String)
}

/// A drawn location identifies its sidebar row, or a search hit whose query the session resolves.
enum MapTarget: Equatable {
    case row(SidebarItem)
    case searchHit(SearchHit.ID)
}

/// The thing selected on the map, whose details the inspector shows; one at a time.
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
    let playerRecords: PlayerRecordsModel
    /// Opens a dimension's document, or brings it to the front if it's open. Each document's view
    /// supplies this, since SwiftUI opens documents through its environment.
    @ObservationIgnored var openDocument: ((URL) async throws -> Void)?
    /// Why another dimension's document couldn't open, until it's been shown.
    var openFailure: String?

    var selectedDimensionID: String? {
        didSet {
            guard oldValue != selectedDimensionID else { return }
            resources.activeDimensionID = selectedDimensionID
            if !isNavigating, let oldValue, let map {
                navigation.record(MapViewLocation(dimension: oldValue, viewport: map.viewport))
            }
            saveView(of: oldValue)   // the map still shows the dimension being left
            if let selection, selection.dimension != selectedDimensionID { self.selection = nil }
            heatMap.dimension = selectedDimensionID
            ruler.clear()
            makeMapForSelection()
        }
    }
    private(set) var map: MapModel?
    /// What the inspector shows, if it's open.
    var inspector: Inspector? {
        didSet {
            guard inspector != oldValue else { return }
            playerRecords.cancel()
            // The inspector shows one thing; showing something else lets go of the map selection,
            // and of World Info or Storage in the sidebar.
            if inspector != .selection, selection != nil { selection = nil }
            if (sidebarSelection == .worldInfo && inspector != .world) || (sidebarSelection == .storage && inspector != .storage) {
                sidebarSelection = nil
            }
        }
    }
    var sidebarSelection: SidebarItem?
    /// Linked-pet jumps also reveal an already-selected row after its group is collapsed again.
    private(set) var sidebarRevealRequest: UUID?
    var showsCoordinateSheet = false
    var placeDraft: SavedPlaceDraft?
    var ruler = MapRuler()
    private(set) var navigation = MapNavigationHistory()
    @ObservationIgnored private var isNavigating = false
    var selection: MapSelection? {
        didSet {
            guard selection != oldValue else { return }
            if selection != nil { inspector = .selection }
            else if inspector == .selection { inspector = nil }
        }
    }
    /// How opaque a selected in-game map is over the terrain.
    var inGameMapOpacity = 0.85
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    var portalsByDimension: [String: [NetherPortal]] { search.portals }
    /// The selected dimension's part of the world index: what its sidebar lists and map show.
    var selectedIndex: DimensionIndex {
        selectedDimensionID.flatMap { search.index.dimensions[$0] } ?? DimensionIndex()
    }

    /// Keep the selected creature's details and map highlight current after a saved health change.
    var currentSelection: MapSelection? {
        guard case .creature(let marker)? = selection else { return selection }
        return .creature(selectedIndex.creatures.first { $0.id == marker.id } ?? marker)
    }

    private var cacheRoot: URL? { resources.cacheRoot }
    private var views: RememberedViews { resources.views }
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var retiringMaps: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]

    convenience init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
                     defaults: UserDefaults = .standard, cacheRoot: URL? = TileCache.root,
                     readRegion: @escaping @Sendable (ChunkseeKit.Dimension, RegionCoordinate) async -> RegionData = RegionData.read) {
        self.init(resources: WorldResources(snapshot: snapshot, names: names, savedSearches: savedSearches,
                                           defaults: defaults, cacheRoot: cacheRoot, readRegion: readRegion))
    }

    init(resources: WorldResources, dimensionID: String? = nil) {
        self.resources = resources
        visibility = LayerVisibility(defaults: resources.defaults)
        let selected = dimensionID ?? resources.defaultDimensionID
        search = SearchModel(readers: [], players: resources.players, names: resources.names,
                             singleplayerUUID: resources.world.level.singleplayerUUID, firstDimension: selected,
                             savedSearches: resources.savedSearches, indexStore: resources.index)
        heatMap = HeatMapLayer(readers: resources.readers)
        playerRecords = PlayerRecordsModel(world: resources.world)
        selectedDimensionID = selected
        heatMap.dimension = selected
        makeMapForSelection()
        resources.attach(self)
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

    /// Closing drains this dimension's reads; the world's shared reads stay alive for the others.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        saveView()
        search.cancel()
        heatMap.cancel()
        playerRecords.close()
        map?.close()
        let search = search, heatMap = heatMap, playerRecords = playerRecords
        let map = map, retiring = Array(retiringMaps.values)
        let task = Task {
            await search.waitForTasks()
            await heatMap.waitForReads()
            await playerRecords.waitForReads()
            await map?.waitForRenders()
            for task in retiring { await task.value }
        }
        closingTask = task
        resources.detach(self, draining: task)
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
        dimensions.first { $0.id == id }?.displayName ?? id
    }

    /// The world spawn when it's in the selected dimension, otherwise the origin.
    var spawnPoint: CGPoint {
        guard let spawn = world.level.spawnPosition,
              (world.level.spawnDimension ?? "minecraft:overworld") == selectedDimensionID else { return .zero }
        return CGPoint(x: spawn.x, y: spawn.z)
    }

    /// Shows a location: switches to its dimension if needed, centers the map on it, and zooms in
    /// to at least 2×, unless `keepingZoom`, as choosing from the sidebar does (Ryan, 2026-10-13).
    func focus(on location: PlayerInfo.Location, keepingZoom: Bool = false) {
        guard dimensions.contains(where: { $0.id == location.dimension }) else { return }
        if route(to: location.dimension, perform: { $0.focus(on: location, keepingZoom: keepingZoom) }) { return }
        navigate {
            selectedDimensionID = location.dimension
            map?.viewport.center = CGPoint(x: location.x, y: location.z)
            if !keepingZoom, let map, map.viewport.scale < 2 { map.viewport.scale = 2 }
        }
    }

    /// Resolve a link again at activation, so refreshed ownership or a removed pet cannot use
    /// stale inspector data. A cross-dimension jump belongs to the destination document.
    func showLinkedPet(_ pet: CreatureMarker, ownedBy playerID: UUID) {
        guard !isClosed,
              let current = search.index.dimensions[pet.dimension]?.creatures.first(where: { $0.id == pet.id && $0.creature.owner == playerID }) else { return }
        if route(to: current.dimension, perform: { $0.showLinkedPet(current, ownedBy: playerID) }) { return }
        selectedDimensionID = current.dimension
        sidebarSelection = .creature(current.id)
        choose(.creature(current.id))
        sidebarRevealRequest = UUID()
    }

    /// Centers the map on a point in the selected dimension.
    func center(on point: CGPoint, keepingZoom: Bool = false) {
        guard let id = selectedDimensionID else { return }
        focus(on: PlayerInfo.Location(dimension: id, x: point.x, y: 64, z: point.y), keepingZoom: keepingZoom)
    }

    /// Coordinate entry changes only the center, keeping the chosen zoom.
    func goToCoordinates(_ point: CGPoint) {
        navigate { map?.viewport.center = point }
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

    func visit(_ place: SavedPlace) {
        guard dimensions.contains(where: { $0.id == place.dimension }) else { return }
        if route(to: place.dimension, perform: { $0.visit(place) }) { return }
        let scale = map?.viewport.scale ?? 1
        navigate {
            selectedDimensionID = place.dimension
            map?.viewport = MapViewport(center: place.position, scale: scale)
        }
    }

    func setRulerEnabled(_ enabled: Bool) {
        ruler.isEnabled = enabled
        if enabled { selection = nil }
    }

    func beginMeasurement(at point: CGPoint, in dimension: String) {
        guard !isClosed, selectedDimensionID == dimension else { return }
        setRulerEnabled(true)
        ruler.clear()
        ruler.mark(point)
    }

    private var currentView: MapViewLocation? {
        guard let map, let dimension = selectedDimensionID else { return nil }
        return MapViewLocation(dimension: dimension, viewport: map.viewport)
    }

    func openDimension(_ id: String) {
        guard !isClosed, dimensions.contains(where: { $0.id == id }) else { return }
        if openDocument != nil { open(id, then: nil) }
        else { selectedDimensionID = id }
    }

    /// Each dimension is its own document; a jump to another dimension happens in that
    /// dimension's document, once it's open.
    private func route(to dimension: String, perform: @escaping (WorldSession) -> Void) -> Bool {
        guard !isClosed, dimension != selectedDimensionID, openDocument != nil else { return false }
        open(dimension, then: perform)
        return true
    }

    /// A jump that can't reach its dimension is dropped, so a later opening doesn't replay it.
    private func open(_ dimension: String, then perform: ((WorldSession) -> Void)?) {
        guard let openDocument, let url = resources.documentURL(for: dimension) else { return }
        let request = perform.flatMap { resources.whenShowing(dimension, perform: $0) }
        let resources = resources
        Task { [weak self] in
            do {
                try await openDocument(url)
            } catch {
                if let request { resources.cancelPending(request, in: dimension) }
                guard !(error is CancellationError), (error as? CocoaError)?.code != .userCancelled else { return }
                self?.openFailure = error.localizedDescription
            }
        }
    }

    /// Capture a whole jump once, even when it also switches dimensions or fits a map.
    private func navigate(_ change: () -> Void) {
        guard !isClosed else { return }
        if isNavigating { change(); return }
        let previous = currentView
        isNavigating = true
        change()
        isNavigating = false
        if let previous, previous != currentView { navigation.record(previous) }
    }

    func goBack() {
        guard !isClosed, let currentView, let destination = navigation.goBack(from: currentView) else { return }
        restore(destination)
    }

    func goForward() {
        guard !isClosed, let currentView, let destination = navigation.goForward(from: currentView) else { return }
        restore(destination)
    }

    private func restore(_ location: MapViewLocation) {
        isNavigating = true
        selectedDimensionID = location.dimension
        map?.viewport = location.viewport
        isNavigating = false
    }

    /// A native document reread or move replaces readers, while keeping window navigation.
    func restoreView(from previous: WorldSession) {
        let dimensions = Set(dimensions.map(\.id))
        navigation = previous.navigation
        navigation.retainDimensions(dimensions)
        if let location = previous.currentView, dimensions.contains(location.dimension) {
            restore(location)
            ruler = previous.ruler
        }
    }

    var canFitWorld: Bool {
        guard let map, let shown = map.shownSize else { return false }
        return MapViewport.fitting(map.availableRegions, in: shown.size) != nil
    }

    func fitWorld() {
        guard let map, let shown = map.shownSize,
              let fitted = MapViewport.fitting(map.availableRegions, in: shown.size) else { return }
        navigate { map.viewport = fitted }
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
        content.placePoints = index.placePoints
        content.shownPlaceGroups = visibility.places
        content.creaturePoints = index.creaturePoints
        content.shownCreatureGroups = visibility.creatures
        content.hits = pinnedHits.filter { $0.dimension == id && $0.position != nil }
        content.selectedHitID = search.selectedHitID
        content.players = PlayerPresentation.markers(for: players.filter { !visibility.hiddenPlayers.contains($0.uuid) }, in: id,
                                                     singleplayerUUID: world.level.singleplayerUUID,
                                                     worldDataVersion: world.level.dataVersion) { [names] in names.name(for: $0) }
        content.selection = currentSelection
        content.selectedPlayerID = if case .player(let uuid)? = inspector { uuid } else { nil }
        content.savedPlaces = savedPlaces.all.filter { $0.dimension == id }
        content.ruler = ruler
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

    /// Shows what a sidebar row stands for, making its layer visible on the map.
    func choose(_ item: SidebarItem) {
        let index = selectedIndex
        switch item {
        case .worldInfo:
            inspector = .world
        case .storage:
            inspector = .storage
        case .savedPlace(let id):
            if let place = savedPlaces.all.first(where: { $0.id == id }) { visit(place) }
        case .structure(let id):
            guard let marker = index.structures.first(where: { $0.id == id }) else { return }
            visibility.structures.insert(marker.group)
            center(on: marker.position, keepingZoom: true)
        case .place(let id):
            guard let marker = index.places.first(where: { $0.id == id }) else { return }
            visibility.places.insert(marker.group)
            if let portal = marker.portal { show(portal, keepingZoom: true) } else { center(on: marker.position, keepingZoom: true) }
        case .creature(let id):
            guard let marker = index.creatures.first(where: { $0.id == id }) else { return }
            visibility.creatures.insert(marker.group)
            center(on: marker.position, keepingZoom: true)
            selection = .creature(marker)
        case .biome(let id):
            guard let area = index.biomeAreas.first(where: { $0.id == id }) else { return }
            visibility.biomes.insert(area.group)
            center(on: area.position, keepingZoom: true)
        case .inGameMap(let id):
            if let map = inGameMaps.first(where: { $0.id == id }) { show(map, keepingZoom: true) }
        case .player(let uuid):
            guard let player = players.first(where: { $0.uuid == uuid }) else { return }
            // A player without a mappable position still has details to show.
            if canFocus(player), let position = player.position { focus(on: position, keepingZoom: true) }
            inspector = .player(uuid)
        case .hit(let query, let id):
            if let hit = search.results(for: query).first(where: { $0.id == id }) { show(hit, keepingZoom: true) }
        }
    }

    /// Selects a marker's row without navigating or taking focus from the map. A portal, creature
    /// or player shows its details, replacing an in-game map overlay. Other markers and empty or
    /// stale clicks keep that overlay, and otherwise close the details, as for a pet (Ryan, 2026-10-16).
    @discardableResult func mapClicked(_ clicked: MapTarget?) -> SidebarItem? {
        let item = clicked.flatMap(sidebarItem(for:))
        // A player's death or respawn marker can be drawn here while their row is in another
        // dimension's sidebar, or while their current position is unknown; it still shows them.
        let player: UUID? = if case .row(.player(let id))? = clicked, drawsMarker(for: id) { id } else { nil }
        if item == nil, player == nil, case .inGameMap? = selection { return nil }
        let detail: MapSelection?
        switch item {
        case .place(let id)?:
            detail = selectedIndex.places.first { $0.id == id }?.portal.map(MapSelection.portal)
        case .creature(let id)?:
            detail = selectedIndex.creatures.first { $0.id == id }.map(MapSelection.creature)
        default:
            detail = nil
        }
        if let detail { selection = detail }
        else if let player { inspector = .player(player) }
        else if case .inGameMap? = selection { /* Keep the map under markers without details. */ }
        else {
            selection = nil
            if case .player? = inspector { inspector = nil }
        }
        search.selectedHitID = if case .hit(_, let id)? = item { id } else { nil }
        if let item { sidebarSelection = item }
        else if sidebarSelection != .worldInfo && sidebarSelection != .storage { sidebarSelection = nil }
        return item
    }

    private func sidebarItem(for target: MapTarget) -> SidebarItem? {
        switch target {
        case .searchHit(let id):
            let queries = (search.isActive ? [search.text] : []) + savedSearches.all.filter(\.isShown).map(\.query)
            for query in queries where listed(search.results(for: query)).prefix(200).contains(where: { $0.id == id }) {
                return .hit(query: query, id: id)
            }
            return nil
        case .row(let item):
            // A live update may have removed the marker since this frame was drawn. Players'
            // death/respawn markers can also belong to somebody listed in another dimension.
            let index = selectedIndex
            let exists = switch item {
            case .structure(let id): index.structures.contains { $0.id == id }
            case .place(let id): index.places.contains { $0.id == id }
            case .creature(let id): index.creatures.contains { $0.id == id }
            case .biome(let id): index.biomeAreas.contains { $0.id == id }
            case .savedPlace(let id): listedPlaces.contains { $0.id == id }
            case .player(let id): drawsMarker(for: id) && listedPlayers.contains { $0.uuid == id }
            default: false
            }
            return exists ? item : nil
        }
    }

    /// Whether this dimension's map draws one of the player's markers: their position, last death
    /// or respawn point. A stale target, such as a hidden or removed player, draws none.
    private func drawsMarker(for playerID: UUID) -> Bool {
        guard let id = selectedDimensionID, !visibility.hiddenPlayers.contains(playerID),
              let player = players.first(where: { $0.uuid == playerID }) else { return false }
        return !PlayerPresentation.markers(for: [player], in: id, singleplayerUUID: world.level.singleplayerUUID,
                                           worldDataVersion: world.level.dataVersion).isEmpty
    }

    /// Whether choosing a player's row can center the map on their current position.
    func canFocus(_ player: PlayerInfo) -> Bool {
        guard PlayerPresentation.isMappable(player), let position = player.position else { return false }
        return dimensions.contains { $0.id == position.dimension }
    }

    /// Remembers where the map is, to reopen there. `dimensionID` is the dimension the map is
    /// showing: the selected one, except while switching away from it.
    func saveView(of dimensionID: String? = nil) {
        guard let map, let id = dimensionID ?? selectedDimensionID else { return }
        views.save(map.viewport, for: id, selected: resources.activeDimensionID)
    }

    // MARK: Search results, portals and in-game maps

    /// Centers the map on a search result, switching dimension if needed, and shows its layer's
    /// kind (a biome's outline, say) so the result is on the map.
    func show(_ hit: SearchHit, keepingZoom: Bool = false) {
        guard let dimension = hit.dimension, let position = hit.position else { return }
        if route(to: dimension, perform: { $0.show(hit, keepingZoom: keepingZoom) }) { return }
        focus(on: PlayerInfo.Location(dimension: dimension, x: position.x, y: Double(hit.y ?? 64), z: position.y), keepingZoom: keepingZoom)
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
    func show(_ portal: NetherPortal, keepingZoom: Bool = false) {
        if route(to: portal.dimension, perform: { $0.show(portal, keepingZoom: keepingZoom) }) { return }
        focus(on: PlayerInfo.Location(dimension: portal.dimension, x: portal.centerX, y: Double(portal.minY), z: portal.centerZ),
              keepingZoom: keepingZoom)
        selection = .portal(portal)
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

    /// A map's picture, made once and kept.
    func image(for map: MapItem) -> CGImage? {
        if let image = inGameMapImages[map.id] { return image }
        let image = InGameMapImage.make(map)
        inGameMapImages[map.id] = image
        return image
    }

    /// Draws an in-game map over the terrain and fits it in view (or only centers it, when
    /// `keepingZoom`), switching dimension if needed.
    func show(_ map: MapItem, keepingZoom: Bool = false) {
        // A map from a missing dimension is listed but not shown, so its coordinates are never
        // drawn over another dimension's terrain.
        guard canShow(map), let dimension = map.dimension else { return }
        if route(to: dimension, perform: { $0.show(map, keepingZoom: keepingZoom) }) { return }
        navigate {
            focus(on: PlayerInfo.Location(dimension: dimension, x: Double(map.centerX), y: 64, z: Double(map.centerZ)),
                  keepingZoom: keepingZoom)
            if !keepingZoom { self.map?.viewport.scale = InGameMapImage.fittingScale(for: map) }
        }
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
        guard let id = selectedDimensionID else { return [] }
        return PlayerPresentation.listed(players, in: id, dimensions: dimensions.map(\.id))
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
