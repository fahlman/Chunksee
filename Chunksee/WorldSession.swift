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
    let slimeChunks: SlimeChunkLayer
    let playerRecords: PlayerRecordsModel
    /// Opens a dimension's document, or brings it to the front if it's open. Each document's view
    /// supplies this, since SwiftUI opens documents through its environment.
    @ObservationIgnored var openDocument: ((URL) async throws -> Void)?
    /// Why another dimension's document couldn't open, until it's been shown.
    var openFailure: String?

    let selectedDimensionID: String?
    let map: MapModel?
    private var selectedItem: SidebarItem?
    private var inspectorIsShown = false
    /// An in-game map can remain under a selected marker that has no details of its own.
    private var overlayID: Int?

    /// Content and highlights are derived from one identity and the current world data.
    var inspector: Inspector? {
        get {
            guard inspectorIsShown else { return nil }
            switch selectedItem.flatMap(resolve) {
            case .worldInfo?: return .world
            case .storage?: return .storage
            case .player(let player)?: return .player(player.uuid)
            default: return selection == nil ? nil : .selection
            }
        }
        set {
            switch newValue {
            case .world?: select(.worldInfo)
            case .storage?: select(.storage)
            case .player(let id)?: select(.player(id))
            case .selection?: inspectorIsShown = true
            case nil:
                let previous = inspector
                inspectorIsShown = false
                overlayID = nil
                if selectedItem == .worldInfo || selectedItem == .storage { selectedItem = nil }
                if inspector != previous { playerRecords.cancel() }
            }
        }
    }
    var sidebarSelection: SidebarItem? {
        guard let item = selectedItem, resolve(item) != nil else { return nil }
        if case .player(let id) = item, !listedPlayers.contains(where: { $0.uuid == id }) { return nil }
        return item
    }
    var selectedHitID: SearchHit.ID? {
        if case .hit(_, let id)? = sidebarSelection { return id }
        return nil
    }
    /// Linked-pet jumps also reveal an already-selected row after its group is collapsed again.
    private(set) var sidebarRevealRequest: UUID?
    var showsCoordinateSheet = false
    var placeDraft: SavedPlaceDraft?
    var ruler = MapRuler()
    private(set) var navigation = MapNavigationHistory()
    var selection: MapSelection? {
        guard inspectorIsShown else { return nil }
        switch selectedItem.flatMap(resolve) {
        case .creature(let marker)?: return .creature(marker)
        case .place(let marker)?:
            if let portal = marker.portal { return .portal(portal) }
        default: break
        }
        guard let overlayID, let map = inGameMaps.first(where: { $0.id == overlayID }), canShow(map) else { return nil }
        return .inGameMap(map)
    }
    /// How opaque a selected in-game map is over the terrain.
    var inGameMapOpacity = 0.85
    /// Every Nether portal in the Overworld and the Nether, by dimension id, for predicting links.
    var portalsByDimension: [String: [NetherPortal]] { search.portals }
    /// The selected dimension's part of the world index: what its sidebar lists and map show.
    var selectedIndex: DimensionIndex {
        selectedDimensionID.flatMap { search.index.dimensions[$0] } ?? DimensionIndex()
    }

    var currentSelection: MapSelection? { selection }

    private var views: RememberedViews { resources.views }
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]

    convenience init(snapshot: WorldSnapshot, names: PlayerNames, savedSearches: SavedSearches,
                     defaults: UserDefaults, cacheRoot: URL?,
                     readRegion: @escaping RegionReader.Read = RegionReader.scan) {
        self.init(resources: WorldResources(snapshot: snapshot, names: names, savedSearches: savedSearches,
                                           defaults: defaults, cacheRoot: cacheRoot, readRegion: readRegion))
    }

    init(resources: WorldResources, dimensionID: String? = nil) {
        self.resources = resources
        let selected = dimensionID ?? resources.defaultDimensionID
        visibility = LayerVisibility(world: resources.url, dimension: selected, defaults: resources.defaults)
        search = SearchModel(readers: [], work: resources.backgroundWork, playerSnapshot: resources.playerSnapshot, names: resources.names,
                             singleplayerUUID: resources.world.level.singleplayerUUID, firstDimension: selected,
                             savedSearches: resources.savedSearches, indexStore: resources.index)
        heatMap = HeatMapLayer(reader: selected.flatMap { resources.readers[$0] }, work: resources.backgroundWork)
        playerRecords = PlayerRecordsModel(world: resources.world, work: resources.backgroundWork)
        selectedDimensionID = selected
        let initialMap = Self.initialMap(resources: resources, dimensionID: selected)
        map = initialMap
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
        playerRecords.close()
        map?.close()
        let search = search, heatMap = heatMap, slimeChunks = slimeChunks, playerRecords = playerRecords
        let map = map
        let task = Task {
            await search.waitForTasks()
            await heatMap.waitForReads()
            await slimeChunks.waitForImages()
            await playerRecords.waitForReads()
            await map?.waitForRenders()
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
        if route(to: location.dimension, perform: { $0.focus(on: location, blockPosition: blockPosition, keepingZoom: keepingZoom) }) { return }
        navigate {
            let point = CGPoint(x: location.x, y: location.z)
            map?.viewport.center = blockPosition ? MapCoordinates.center(of: point) : point
            if !keepingZoom, let map, map.viewport.scale < 2 { map.viewport.scale = 2 }
        }
    }

    /// Resolve a link again at activation, so refreshed ownership or a removed pet cannot use
    /// stale inspector data. A cross-dimension jump belongs to the destination document.
    func showLinkedPet(_ pet: CreatureMarker, ownedBy playerID: UUID) {
        guard !isClosed,
              let current = search.index.dimensions[pet.dimension]?.creatures.first(where: { $0.id == pet.id && $0.creature.owner == playerID }) else { return }
        if route(to: current.dimension, perform: { $0.showLinkedPet(current, ownedBy: playerID) }) { return }
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
        guard let coordinates = MapCoordinates(point: point) else { return }
        navigate { map?.viewport.center = coordinates.center }
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
        if route(to: place.dimension, perform: { $0.visit(place) }) { return }
        let scale = map?.viewport.scale ?? 1
        navigate {
            map?.viewport = MapViewport(center: place.mapPosition, scale: scale)
        }
    }

    func setRulerEnabled(_ enabled: Bool) {
        ruler.isEnabled = enabled
        if enabled, selection != nil { inspector = nil }
    }

    func beginMeasurement(at point: CGPoint, in dimension: String) {
        guard !isClosed, selectedDimensionID == dimension else { return }
        setRulerEnabled(true)
        ruler.clear()
        ruler.mark(point)
    }

    private var currentView: MapViewport? { map?.viewport }

    func openDimension(_ id: String) {
        guard !isClosed, dimensions.contains(where: { $0.id == id }) else { return }
        open(id, then: nil)
    }

    /// Each dimension is its own document; a jump to another dimension happens in that
    /// dimension's document, once it's open.
    private func route(to dimension: String, perform: @escaping (WorldSession) -> Void) -> Bool {
        guard !isClosed, dimension != selectedDimensionID else { return false }
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

    /// History belongs to this document. A routed jump records its destination's viewport.
    private func navigate(_ change: () -> Void) {
        guard !isClosed else { return }
        let previous = currentView
        change()
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

    private func restore(_ viewport: MapViewport) { map?.viewport = viewport }

    /// A native document reread or move replaces readers, while keeping window navigation.
    func restoreView(from previous: WorldSession) {
        guard selectedDimensionID == previous.selectedDimensionID, map != nil,
              let viewport = previous.currentView else { return }
        navigation = previous.navigation
        restore(viewport)
        if let depth = previous.map?.depth { map?.setDepth(depth) }
        ruler = previous.ruler
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
        content.slimeChunks = slimeChunks.visibleImages
        content.slimeSeed = slimeChunks.visibleSeed
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
        content.selectedHitID = selectedHitID
        content.players = drawnPlayerMarkers
        content.selection = currentSelection
        content.selectedItem = sidebarSelection
        content.selectedPlayerID = if case .player(let uuid)? = inspector { uuid } else { nil }
        content.savedPlaces = savedPlaces.all.filter { $0.dimension == id }
        content.ruler = ruler
        return content
    }

    private static func initialMap(resources: WorldResources, dimensionID: String?) -> MapModel? {
        guard let dimension = resources.dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        let map = MapModel(dimension: dimension, center: spawnPoint(in: resources.world, dimensionID: dimensionID),
                           cacheDirectory: TileCache.directory(forWorldAt: resources.url, dimensionID: dimension.id, root: resources.cacheRoot))
        if let viewport = resources.views.viewport(for: dimension.id) { map.viewport = viewport }
        map.setDepth(resources.views.depth(for: dimension.id))
        return map
    }

    /// Resolves every selectable identity in one place, without retaining an old marker snapshot.
    func resolve(_ item: SidebarItem) -> ResolvedSidebarItem? {
        let index = selectedIndex
        switch item {
        case .worldInfo: return .worldInfo
        case .storage: return .storage
        case .savedPlace(let id): return listedPlaces.first { $0.id == id }.map(ResolvedSidebarItem.savedPlace)
        case .structure(let id): return index.structures.first { $0.id == id }.map(ResolvedSidebarItem.structure)
        case .place(let id): return index.places.first { $0.id == id }.map(ResolvedSidebarItem.place)
        case .creature(let id): return index.creatures.first { $0.id == id }.map(ResolvedSidebarItem.creature)
        case .biome(let id): return index.biomeAreas.first { $0.id == id }.map(ResolvedSidebarItem.biome)
        case .inGameMap(let id): return inGameMaps.first { $0.id == id }.map(ResolvedSidebarItem.inGameMap)
        case .player(let id): return players.first { $0.uuid == id }.map(ResolvedSidebarItem.player)
        case .hit(let query, let id):
            guard (search.isActive && query == search.text) || savedSearches.contains(query) else { return nil }
            return listedHits(for: query).rows.first { $0.id == id }.map(ResolvedSidebarItem.hit)
        }
    }

    /// Changes selection for every input path. Overlay retention is independent of row selection.
    private func select(_ item: SidebarItem?, preservingGlobalRows: Bool = false) {
        guard !isClosed else { return }
        if item == nil, preservingGlobalRows {
            if selectedItem == .worldInfo || selectedItem == .storage { return }
            if case .inGameMap(let id)? = selectedItem, overlayID == id { return }
        }
        let previous = inspector
        let resolved = item.flatMap(resolve)
        selectedItem = resolved == nil ? nil : item
        switch resolved {
        case .worldInfo?, .storage?, .player?, .creature?: overlayID = nil
        case .place(let marker)?:
            if marker.portal != nil { overlayID = nil }
        case .inGameMap(let map)?: overlayID = map.id
        case .savedPlace?, .structure?, .biome?, .hit?, nil: break
        }
        inspectorIsShown = true
        if inspector != previous { playerRecords.cancel() }
    }

    /// Only sidebar input navigates and reveals a hidden layer; map input keeps map focus/viewport.
    func choose(_ item: SidebarItem?) {
        guard !isClosed else { return }
        guard let item, let resolved = resolve(item) else { select(nil); return }
        switch resolved {
        case .worldInfo, .storage: break
        case .savedPlace(let place):
            guard canVisit(place) else { return }
            visit(place)
        case .structure(let marker):
            visibility.structures.insert(marker.group)
            center(on: marker.position, keepingZoom: true)
        case .place(let marker):
            visibility.places.insert(marker.group)
            center(on: marker.position, keepingZoom: true)
        case .creature(let marker):
            visibility.creatures.insert(marker.group)
            center(on: marker.position, keepingZoom: true)
        case .biome(let area):
            visibility.biomes.insert(area.group)
            center(on: area.position, keepingZoom: true)
        case .inGameMap(let map):
            guard canShow(map) else { return }
            show(map, keepingZoom: true)
        case .player(let player):
            visibility.hiddenPlayers.remove(player.uuid)
            if canFocus(player), let position = player.position { focus(on: position, keepingZoom: true) }
        case .hit(let hit):
            guard let dimension = hit.dimension, let position = hit.position else { return }
            focus(on: PlayerInfo.Location(dimension: dimension, x: position.x, y: Double(hit.y ?? 64), z: position.y), keepingZoom: true)
            if case .layer(let layer) = hit.source {
                switch layer {
                case .structure(let group): visibility.structures.insert(group)
                case .place(let group): visibility.places.insert(group)
                case .creature(let group): visibility.creatures.insert(group)
                case .biome(let group): visibility.biomes.insert(group)
                }
            }
        }
        select(item)
    }

    /// Selects the current target without navigating. A player's death/respawn marker can show
    /// details here even when their row belongs to another dimension.
    @discardableResult func mapClicked(_ clicked: MapTarget?) -> SidebarItem? {
        let item: SidebarItem?
        switch clicked {
        case .searchHit(let id)?: item = searchRow(for: id)
        case .row(let row)?:
            switch row {
            case .player(let id): item = drawsMarker(for: id) ? row : nil
            case .savedPlace, .structure, .place, .creature, .biome, .hit:
                item = resolve(row) == nil ? nil : row
            case .worldInfo, .storage, .inGameMap: item = nil
            }
        case nil: item = nil
        }
        select(item, preservingGlobalRows: true)
        return item == nil ? nil : sidebarSelection
    }

    private func searchRow(for id: SearchHit.ID) -> SidebarItem? {
        for query in visibleSearchQueries where listedHits(for: query).rows.contains(where: { $0.id == id }) {
            return .hit(query: query, id: id)
        }
        return nil
    }

    /// Whether this dimension's map draws one of the player's markers: their position, last death
    /// or respawn point. A stale target, such as a hidden or removed player, draws none.
    private func drawsMarker(for playerID: UUID) -> Bool {
        drawnPlayerMarkers.contains { $0.playerID == playerID }
    }

    private var drawnPlayerMarkers: [MapMarker] {
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

    private var visibleSearchQueries: [String] {
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

    /// Selects a portal and centers the map on it, switching dimension if needed.
    func show(_ portal: NetherPortal, keepingZoom: Bool = false) {
        if route(to: portal.dimension, perform: { $0.show(portal, keepingZoom: keepingZoom) }) { return }
        focus(on: PlayerInfo.Location(dimension: portal.dimension, x: portal.centerX, y: Double(portal.minY), z: portal.centerZ),
              keepingZoom: keepingZoom)
        select(.place(PlaceMarker(portal).id))
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
        select(.inGameMap(map.id))
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
