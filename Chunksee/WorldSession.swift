import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeIndex
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
    var players: [PlayerInfo] { search.playerSnapshot.players }
    var visibility: LayerVisibility {
        get { mapPresentation.overlays }
        set {
            guard !isClosed else { return }
            if let map { map.setOverlays(newValue) }
            else {
                var choices = mapPresentation
                choices.overlays = newValue
                mapState = .unavailable(choices)
            }
        }
    }
    let search: SearchModel
    @ObservationIgnored private(set) lazy var heatMap = HeatMapLayer(
        reader: { [weak self] in
            guard let self, let id = self.selectedDimensionID else { return nil }
            return self.resources.readers[id]
        }, isShown: { [weak self] in self?.visibility.showsTimeSpent ?? false }, work: resources.backgroundWork)
    @ObservationIgnored private(set) lazy var slimeChunks = SlimeChunkLayer(
        dimensionID: selectedDimensionID, seed: { [weak self] in self?.resources.details.seed },
        isShown: { [weak self] in self?.visibility.showsSlimeChunks ?? false },
        regions: map?.availableRegions ?? [], work: resources.backgroundWork)
    /// Created after initialization so feature models can refer weakly to this document.
    @ObservationIgnored private(set) lazy var routing = DimensionRouting(source: self)
    @ObservationIgnored private(set) lazy var selection = SelectionModel(source: self)
    @ObservationIgnored private(set) lazy var annotations = MapAnnotations(source: self)
    @ObservationIgnored private(set) lazy var presentation = DimensionPresentation(source: self)
    @ObservationIgnored private(set) lazy var imageExport = MapExportModel(source: self)

    let selectedDimensionID: String?
    // A dimension may not exist yet. Transfer its choices into MapModel when it becomes readable;
    // retaining a second fallback copy beside a loaded map would give those choices two owners.
    private enum MapState {
        case unavailable(MapPresentation)
        case loaded(MapModel)
    }
    private var mapState: MapState
    var map: MapModel? {
        guard case .loaded(let map) = mapState else { return nil }
        return map
    }
    private var mapPresentation: MapPresentation {
        switch mapState {
        case .unavailable(let choices): choices
        case .loaded(let map): map.presentation
        }
    }
    @ObservationIgnored private let renderTile: @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
    let navigation: MapNavigation
    var sheet: WorldSheet? {
        didSet {
            // Cancellation belongs to dismissal, not the timing of a disappearing view.
            if oldValue?.id == .imageExport, sheet?.id != .imageExport { imageExport.cancel() }
            // A dismissed or replaced statistics sheet releases only its own demand. The
            // inspector and sibling windows keep their handles to the same shared result.
            if let previous = oldValue?.playerRecords, previous !== sheet?.playerRecords { previous.close() }
        }
    }
    var commandTarget: WorldSession? { !isClosed && sheet == nil ? self : nil }
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var presentationObservation: ModelObservation?

    init(resources: WorldResources, dimensionID: String? = nil,
         renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
            = { try await $0.tile(for: $1) }) {
        self.resources = resources
        let renderAfterPreparation: @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile? = {
            [weak resources] renderer, region in
            guard let resources else { throw CancellationError() }
            try await resources.waitForCachePreparation()
            return try await renderTile(renderer, region)
        }
        self.renderTile = renderAfterPreparation
        let selected = dimensionID ?? resources.defaultDimensionID
        let choices = resources.settings.mapPresentation(for: selected)
        search = SearchModel(queryStore: resources.queryStore)
        selectedDimensionID = selected
        let initialMap = Self.initialMap(resources: resources, dimensionID: selected, choices: choices, renderTile: renderAfterPreparation)
        mapState = initialMap.map(MapState.loaded) ?? .unavailable(choices)
        navigation = MapNavigation(map: initialMap)
        search.captureBlockOrigin { [weak self] in
            guard let self, !self.isClosed, let dimension = self.selectedDimensionID, let map = self.map else { return nil }
            if case .player(let id)? = self.selection.sidebarSelection,
               let player = self.players.first(where: { $0.uuid == id }),
               let location = PlayerPresentation.position(of: player),
               location.dimension == dimension, let origin = BlockSearchOrigin(x: location.x, z: location.z) {
                return BlockSearchAnchor(point: .init(dimension: dimension, origin: origin), playerID: id)
            }
            guard let origin = BlockSearchOrigin(x: map.viewport.center.x, z: map.viewport.center.y) else { return nil }
            return BlockSearchAnchor(point: .init(dimension: dimension, origin: origin), playerID: nil)
        }
        observeMapPresentation()
        _ = heatMap
        _ = slimeChunks
        resources.attach(self)
    }

    func prepareWorldSourceReplacement() {
        imageExport.cancel()
        map?.replaceSource(world: resources.readSource, dimension: nil, cacheDirectory: nil)
    }

    /// The session and all of its window state stay alive while the shared world changes inputs.
    func replaceWorldSource() {
        guard !isClosed else { return }
        let dimension = resources.dimensions.first { $0.id == selectedDimensionID }
        if let map {
            map.replaceSource(world: resources.readSource, dimension: dimension, cacheDirectory: dimension.flatMap {
                TileCache.directory(forWorldAt: resources.url, dimensionID: $0.id, root: resources.cacheRoot)
            })
        } else if let map = Self.initialMap(resources: resources, dimensionID: selectedDimensionID,
                                           choices: mapPresentation, renderTile: renderTile) {
            mapState = .loaded(map)
            navigation.replaceMap(map)
        }
        slimeChunks.regionsChanged(map?.availableRegions ?? [])
    }

    /// Closing drains this dimension's reads; the world's shared reads stay alive for the others.
    func close() {
        guard !isClosed else { return }
        presentationObservation?.cancel()
        isClosed = true
        sheet = nil
        saveView()
        search.cancel()
        heatMap.cancel()
        slimeChunks.cancel()
        selection.close()
        imageExport.close()
        map?.close()
        let search = search, heatMap = heatMap, slimeChunks = slimeChunks
        let map = map, imageExport = imageExport
        let task = Task {
            await search.waitForTasks()
            await heatMap.waitForReads()
            await slimeChunks.waitForImages()
            await map?.waitForRenders()
            await imageExport.waitUntilIdle()
        }
        closingTask = task
        resources.detach(self)
    }

    func presentSheet(_ sheet: WorldSheet) {
        guard !isClosed else { return }
        self.sheet = sheet
    }

    func showStatistics(for player: UUID) {
        guard !isClosed, let records = resources.playerRecords.acquire(player) else { return }
        sheet = .statistics(records)
    }

    func waitUntilClosed() async {
        await closingTask?.value
        if resources.isClosed { await resources.waitUntilClosed() }
    }

    private static func initialMap(resources: WorldResources, dimensionID: String?, choices: MapPresentation,
                                   renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?) -> MapModel? {
        guard let dimension = resources.dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        let map = MapModel(definitions: { [weak resources] in
                               guard let resources else { return .unknown }
                               return MapDefinitions(dimensionID: dimension.id, definitions: resources.details.definitions)
                           },
                           gameResources: { [weak resources] in resources?.mapGameResources ?? .unavailable },
                           savedLighting: { [weak resources] in resources?.savedLighting(in: dimension.id) },
                           nightLighting: { [weak resources] in resources?.nightLighting(in: dimension.id) },
                           work: resources.backgroundWork, world: resources.readSource, dimension: dimension,
                           center: DimensionPresentation.spawnPoint(in: resources.world, dimensionID: dimensionID),
                           presentation: choices,
                           cacheDirectory: TileCache.directory(forWorldAt: resources.url, dimensionID: dimension.id, root: resources.cacheRoot),
                           renderTile: renderTile)
        if let viewport = resources.settings.viewport(for: dimension.id) { map.viewport = viewport }
        return map
    }

    func setDarkSpots(_ shown: Bool) {
        guard !isClosed, let map, map.showsDarkSpots != shown else { return }
        map.setDarkSpots(shown)
    }

    /// Save the whole choice value independently of the view lifetime. The main-actor observer
    /// also tells the shared index when Dark Spots needs its additional facts.
    private func observeMapPresentation() {
        presentationObservation = ModelObservation(self, isActive: { !$0.isClosed }, read: {
            $0.mapPresentation
        }) { session, previous in
            let current = session.mapPresentation
            guard current != previous else { return }
            session.resources.settings.save(current, for: session.selectedDimensionID)
            if current.overlays.showsDarkSpots != previous.overlays.showsDarkSpots {
                session.resources.darkSpotsVisibilityChanged()
            }
        }
    }

    /// The native front dimension can change without this session switching dimensions.
    func becameActive(isTerminating: Bool = false) {
        guard !isTerminating, !isClosed, !resources.isClosed, let id = selectedDimensionID, map != nil else { return }
        resources.activeDimensionID = id
        saveView()
    }

    /// Remembers this document's viewport while preserving the world's front dimension.
    func saveView() {
        guard let map, let id = selectedDimensionID else { return }
        resources.settings.save(map.viewport, presentation: map.presentation, for: id, selected: resources.activeDimensionID)
    }
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
            String(localized: "Chunksee can’t read this folder as a world.")
        case .needsWorldFolder:
            String(localized: "Chunksee can’t see the world this dimension belongs to.")
        case .unreadable:
            String(localized: "Chunksee couldn’t read this world.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAWorld, .notADimension:
            String(localized: "Open the world’s folder inside your saves folder.")
        case .needsWorldFolder:
            String(localized: "Open the world’s folder, inside your saves folder, instead.")
        case .unreadable:
            String(localized: "It may be from a version Chunksee doesn’t support, or damaged.")
        }
    }
}
