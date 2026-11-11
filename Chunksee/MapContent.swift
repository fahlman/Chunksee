import ChunkseeIndex
import ChunkseeKit
import SwiftUI

/// Everything drawn over one dimension's terrain, bottom to top in this order.
struct MapContent {
    let gameNames: GameNames
    /// Legends and terrain consume the same resolved value, supplied with the scene.
    var terrain: MapDrawingInput
    var mapStyle: MapStyle { terrain.style }
    var lighting: MapLighting? { terrain.lighting }
    var heightScale: MapHeightScale? { terrain.heightScale }
    var blockFilter: MapBlockFilter { terrain.blockFilter }
    var showsDarkSpots: Bool { terrain.showsDarkSpots }
    /// Time-spent heat images by region.
    var heatMap: [RegionPosition: CGImage] = [:]
    var showsHeatMap = false
    /// A map made in the game, drawn where it belongs at the given opacity.
    var inGameMap: (map: MapItem, image: CGImage, opacity: Double)?
    var biomeAreas: [BiomeArea] = []
    var biomeColors: MapBiomeColors?
    /// Each chunk's surface biome and any cave biomes under it, for the hover readout.
    var biomes: [ChunkPosition: String] = [:]
    var caveBiomes: [ChunkPosition: [String]] = [:]
    /// The world border, when it's closer than Minecraft's default.
    var border: WorldBorder?
    /// Whether chunk and region lines are drawn.
    var showsGrid = false
    var slimeChunks: [RegionPosition: CGImage] = [:]
    var slimeSeed: Int64?
    var structures: [StructureMarker] = []
    var placePoints = PointMarkers<PlaceMarker>()
    var creaturePoints = PointMarkers<CreatureMarker>()
    /// Nil means all groups (standalone map snapshots); a document supplies its own visibility.
    var shownPlaceGroups: Set<PlaceGroup>?
    var shownCreatureGroups: Set<CreatureGroup>?
    var shownMobTypes: Set<String> = []
    var mobAppearances: [String: MobAppearance] = [:]
    var places: [PlaceMarker] {
        get { placePoints.all.filter { shownPlaceGroups?.contains($0.group) ?? true } }
        set { placePoints = PointMarkers(newValue) }
    }
    var creatures: [CreatureMarker] {
        get { creaturePoints.all.filter(showsCreature) }
        set { creaturePoints = PointMarkers(newValue) }
    }
    /// Search results, drawn as pins.
    var hits: [SearchHit] = []
    var selectedHitID: SearchHit.ID?
    /// Players' positions, last deaths and respawn points.
    var players: [MapMarker] = []
    /// The player whose details the inspector shows; their position is drawn highlighted.
    var selectedPlayerID: UUID?
    var savedPlaces: [SavedPlace] = []
    var ruler = MapRuler()
    /// The selected portal or creature, drawn highlighted.
    var selection: MapSelection?
    /// The resolved sidebar identity, used to prioritize its label without another selection owner.
    var selectedItem: SidebarItem?

    /// The surface biome of the chunk under a block, once the dimension has been read.
    func biome(at block: CGPoint) -> String? {
        guard let chunk = Self.chunk(at: block) else { return nil }
        return biomes[chunk]
    }

    /// The hover readout's biomes: the surface biome, then any cave biomes below it, as in
    /// "Plains · Deep Dark below".
    func biomeDescription(at block: CGPoint) -> String? {
        guard let chunk = Self.chunk(at: block) else { return nil }
        return gameNames.biomeDescription(surface: biomes[chunk], caves: caveBiomes[chunk] ?? [])
    }

    private static func chunk(at block: CGPoint) -> ChunkPosition? {
        guard let point = MapCoordinates(point: block) else { return nil }
        return ChunkPosition(containingBlockX: Int(point.x), blockZ: Int(point.z))
    }

    func nearbyPlaces(viewport: MapViewport, size: CGSize, bounds: CGRect? = nil) -> [PlaceMarker] {
        guard shownPlaceGroups?.isEmpty != true else { return [] }
        return placePoints.candidates(in: bounds ?? CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20),
                                      viewport: viewport, size: size)
            .filter { (shownPlaceGroups?.contains($0.group) ?? true) && (viewport.scale >= 0.125 || $0.group == .portal) }
    }

    func nearbyCreatures(viewport: MapViewport, size: CGSize, bounds: CGRect? = nil) -> [CreatureMarker] {
        guard shownCreatureGroups?.isEmpty != true || !shownMobTypes.isEmpty else { return [] }
        return creaturePoints.candidates(in: bounds ?? CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20),
                                         viewport: viewport, size: size)
            .filter { showsCreature($0) && (viewport.scale >= 0.25 || selection == .creature($0)) }
    }

    private func showsCreature(_ marker: CreatureMarker) -> Bool {
        if shownCreatureGroups?.contains(marker.group) ?? true { return true }
        guard shownMobTypes.contains(marker.creature.id) else { return false }
        guard let appearance = mobAppearances[marker.creature.id] else { return true }
        return appearance == MobAppearance(marker.creature.appearance)
    }

    /// The individual locations represented by Canvas. Names and actions remain available
    /// to VoiceOver even though Canvas itself creates no accessibility children.
    func accessibleLocations(viewport: MapViewport, size: CGSize) -> [AccessibleMapLocation] {
        scene(viewport: viewport, size: size).accessibleLocations
    }

    /// Hit tests only drawn markers. Match drawing order for overlapping badges, preserving a
    /// portal's priority over a creature standing in it. Names are not prepared for hit testing.
    func target(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapTarget? {
        hit(at: point, viewport: viewport, size: size)?.target
    }

    func hit(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapHit? {
        // Biome areas remain accessible without an invisible pointer badge.
        scene(viewport: viewport, size: size, pickingAt: point).hit(at: point)
    }

    /// A marker's saved location, or the empty block under the pointer, for every map action.
    func location(at point: CGPoint, viewport: MapViewport, size: CGSize) -> (position: CGPoint, y: Double?, target: MapTarget?)? {
        guard let block = MapCoordinates(point: viewport.blockPoint(at: point, in: size)) else { return nil }
        let hit = hit(at: point, viewport: viewport, size: size)
        return (hit?.position ?? block.position, hit?.y, hit?.target)
    }
}

extension MapContent {
    /// A value projected from live document models, without retaining the document or a cache.
    init(session: WorldSession) {
        let map = session.map
        self.init(gameNames: session.resources.gameNames, terrain: map?.drawingInput
            ?? MapDrawingInput(presentation: MapPresentation(), heightScale: nil, savedLighting: nil))
        guard map != nil, let id = session.selectedDimensionID else { return }
        let index = session.presentation.selectedIndex
        heatMap = session.heatMap.visibleImages ?? [:]
        showsHeatMap = session.heatMap.isShown
        slimeChunks = session.slimeChunks.visibleImages
        slimeSeed = session.slimeChunks.visibleSeed
        if case .inGameMap(let item)? = session.selection.mapSelection, let image = session.selection.image(for: item) {
            inGameMap = (item, image, session.selection.inGameMapOpacity)
        }
        biomeAreas = index.biomeAreas.filter { session.visibility.biomes.contains($0.group) }
        biomeColors = session.resources.biomeColors
        biomes = index.biomes
        caveBiomes = index.caveBiomes
        border = session.visibility.showsWorldBorder ? session.presentation.limitedWorldBorder : nil
        showsGrid = session.visibility.showsGrid
        structures = index.structures.filter { session.visibility.structures.contains($0.group) }
        placePoints = index.placePoints
        shownPlaceGroups = session.visibility.places
        creaturePoints = index.creaturePoints
        shownCreatureGroups = session.visibility.creatures
        shownMobTypes = session.visibility.mobTypes
        mobAppearances = Dictionary(uniqueKeysWithValues: index.mobTypes.kinds.compactMap { kind in
            session.visibility.appearance(for: kind).map { (kind.id, $0) }
        })
        hits = session.search.pinnedHits(where: session.presentation.lists).filter { $0.dimension == id && $0.position != nil }
        selectedHitID = session.selection.selectedHitID
        players = session.presentation.drawnPlayerMarkers
        selection = session.selection.mapSelection
        selectedItem = session.selection.sidebarSelection
        selectedPlayerID = if case .player(let uuid)? = session.selection.inspector { uuid } else { nil }
        savedPlaces = session.visibility.showsSavedPlaces ? session.savedPlaces.all.filter { $0.dimension == id } : []
        ruler = session.annotations.ruler
    }
}
