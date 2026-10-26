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
    var players: [PlayerInfo] { search.playerSnapshot.players }
    let visibility: LayerVisibility
    let search: SearchModel
    let heatMap: HeatMapLayer
    let slimeChunks: SlimeChunkLayer
    /// Created after initialization so feature models can refer weakly to this document.
    @ObservationIgnored private(set) lazy var routing = DimensionRouting(source: self)
    @ObservationIgnored private(set) lazy var selection = SelectionModel(source: self)
    @ObservationIgnored private(set) lazy var annotations = MapAnnotations(source: self)
    @ObservationIgnored private(set) lazy var presentation = DimensionPresentation(source: self)
    @ObservationIgnored private(set) lazy var imageExport = MapExportModel(source: self)

    let selectedDimensionID: String?
    let map: MapModel?
    let navigation: MapNavigation
    private(set) var isClosed = false
    @ObservationIgnored private var closingTask: Task<Void, Never>?

    init(resources: WorldResources, dimensionID: String? = nil,
         renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
            = { try await $0.tile(for: $1) }) {
        self.resources = resources
        let selected = dimensionID ?? resources.defaultDimensionID
        visibility = LayerVisibility(settings: resources.settings, dimension: selected)
        search = SearchModel(readers: [], work: resources.backgroundWork, playerRoster: resources.playerRoster, names: resources.names,
                             singleplayerUUID: resources.world.level.singleplayerUUID, firstDimension: selected,
                             savedSearches: resources.savedSearches, indexStore: resources.index)
        heatMap = HeatMapLayer(reader: selected.flatMap { resources.readers[$0] }, work: resources.backgroundWork)
        selectedDimensionID = selected
        let initialMap = Self.initialMap(resources: resources, dimensionID: selected, renderTile: renderTile)
        map = initialMap
        initialMap?.setDarkSpots(visibility.rememberedDarkSpots)
        navigation = MapNavigation(map: initialMap)
        slimeChunks = SlimeChunkLayer(dimensionID: selected, seed: resources.details.seed,
                                     regions: initialMap?.availableRegions ?? [], work: resources.backgroundWork)
        heatMap.restoreVisibility(from: visibility)
        slimeChunks.restoreVisibility(from: visibility)
        resources.attach(self)
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
        imageExport.close()
        map?.close()
        let search = search, heatMap = heatMap, slimeChunks = slimeChunks, selection = selection
        let map = map, imageExport = imageExport
        let task = Task {
            await search.waitForTasks()
            await heatMap.waitForReads()
            await slimeChunks.waitForImages()
            await selection.waitForReads()
            await map?.waitForRenders()
            await imageExport.waitUntilIdle()
        }
        closingTask = task
        resources.detach(self)
    }

    func waitUntilClosed() async {
        await closingTask?.value
        if resources.isClosed { await resources.waitUntilClosed() }
    }

    /// A native document reread or move replaces readers, while keeping window navigation.
    func restoreView(from previous: WorldSession) {
        guard !isClosed, selectedDimensionID == previous.selectedDimensionID, map != nil, previous.map != nil else { return }
        navigation.restore(from: previous.navigation)
        annotations.restore(from: previous.annotations)
    }

    private static func initialMap(resources: WorldResources, dimensionID: String?,
                                   renderTile: @escaping @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?) -> MapModel? {
        guard let dimension = resources.dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        // Start where the map was left, or else at the world spawn when it's in this dimension,
        // otherwise at the origin.
        let map = MapModel(work: resources.backgroundWork, dimension: dimension, center: DimensionPresentation.spawnPoint(in: resources.world, dimensionID: dimensionID),
                           cacheDirectory: TileCache.directory(forWorldAt: resources.url, dimensionID: dimension.id, root: resources.cacheRoot),
                           surfaceContext: MapSurfaceContext(settings: resources.details.dimensionSettings[dimension.id],
                                                             water: resources.details.definitions.water),
                           heightScale: MapHeightScale(settings: resources.details.dimensionSettings[dimension.id]),
                           renderTile: renderTile)
        if let viewport = resources.settings.viewport(for: dimension.id) { map.viewport = viewport }
        map.setDepth(resources.settings.depth(for: dimension.id))
        map.setStyle(resources.settings.style(for: dimension.id))
        map.setBiomeBlending(resources.settings.blendsBiomeColors(for: dimension.id))
        map.setLightingMode(resources.settings.lightingMode(for: dimension.id))
        map.setCastsShadows(resources.settings.castsShadows(for: dimension.id))
        map.setBlockFilter(resources.settings.blockFilter(for: dimension.id))
        return map
    }

    func setDarkSpots(_ shown: Bool) {
        guard !isClosed, let map, map.showsDarkSpots != shown else { return }
        visibility.rememberDarkSpots(shown)
        map.setDarkSpots(shown)
        resources.darkSpotsVisibilityChanged()
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
        resources.settings.save(map.viewport, for: id, selected: resources.activeDimensionID, depth: map.depth, style: map.style,
                                blockFilter: map.blockFilter, blendsBiomeColors: map.blendsBiomeColors,
                                lightingMode: map.lightingMode, castsShadows: map.castsShadows)
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
