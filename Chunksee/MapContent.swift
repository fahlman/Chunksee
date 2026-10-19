import ChunkseeKit
import SwiftUI

/// Everything drawn over one dimension's terrain, bottom to top in this order.
struct MapContent {
    /// Time-spent heat images by region.
    var heatMap: [RegionPosition: CGImage] = [:]
    /// A map made in the game, drawn where it belongs at the given opacity.
    var inGameMap: (map: MapItem, image: CGImage, opacity: Double)?
    var biomeAreas: [BiomeArea] = []
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
    var places: [PlaceMarker] {
        get { placePoints.all.filter { shownPlaceGroups?.contains($0.group) ?? true } }
        set { placePoints = PointMarkers(newValue) }
    }
    var creatures: [CreatureMarker] {
        get { creaturePoints.all.filter { shownCreatureGroups?.contains($0.group) ?? true } }
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
        let surface = biome(at: block).map(ReadableName.from)
        let caves = (caveBiomes[chunk] ?? []).map(ReadableName.from)
        let below = caves.isEmpty ? nil : String(localized: "\(caves.formatted(.list(type: .and))) below")
        let parts = [surface, below].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        guard shownCreatureGroups?.isEmpty != true else { return [] }
        return creaturePoints.candidates(in: bounds ?? CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20),
                                         viewport: viewport, size: size)
            .filter { (shownCreatureGroups?.contains($0.group) ?? true) && (viewport.scale >= 0.25 || selection == .creature($0)) }
    }

    /// The individual locations represented by Canvas. Names and actions remain available
    /// to VoiceOver even though Canvas itself creates no accessibility children.
    func accessibleLocations(viewport: MapViewport, size: CGSize) -> [AccessibleMapLocation] {
        var locations: [AccessibleMapLocation] = []
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        // Ids and names are built only for locations in view: a world can have thousands of
        // spawners and other places off screen.
        func add(_ id: @autoclosure () -> String, _ name: @autoclosure () -> String, _ position: CGPoint,
                 y: Double? = nil, anchor: CGPoint? = nil, frame: @autoclosure () -> CGRect,
                 target: @autoclosure () -> MapTarget? = nil) {
            guard bounds.contains(viewport.viewPoint(for: anchor ?? position, in: size)) else { return }
            locations.append(.init(id: id(), name: name(), position: position, y: y, target: target(), anchor: anchor, frame: frame()))
        }
        func frame(_ geometry: MarkerGeometry, at position: CGPoint) -> CGRect {
            geometry.frame(at: viewport.viewPoint(for: position, in: size))
        }
        for marker in structures {
            add("structure-" + marker.id, marker.name, marker.position, y: marker.y.map(Double.init),
                frame: frame(.structure, at: marker.position), target: .row(.structure(marker.id)))
        }
        for marker in nearbyPlaces(viewport: viewport, size: size) {
            add("place-" + marker.id, marker.name, marker.position, y: Double(marker.y),
                frame: frame(.place(isPortal: marker.group == .portal), at: marker.position), target: .row(.place(marker.id)))
        }
        for marker in nearbyCreatures(viewport: viewport, size: size) {
            add("creature-" + marker.id, marker.name, marker.position, y: marker.creature.y,
                frame: frame(.creature(selected: selection == .creature(marker)), at: marker.position), target: .row(.creature(marker.id)))
        }
        for area in biomeAreas {
            add("biome-" + area.id, area.group.name, area.position,
                frame: CGRect(origin: viewport.viewPoint(for: area.bounds.origin, in: size),
                              size: CGSize(width: area.bounds.width * viewport.scale, height: area.bounds.height * viewport.scale)),
                target: .row(.biome(area.id)))
        }
        for hit in hits {
            if let position = hit.position {
                add("search-" + hit.id, hit.title + ", " + hit.detail, position, y: hit.y.map(Double.init),
                    frame: frame(.search(selected: hit.id == selectedHitID), at: position), target: .searchHit(hit.id))
            }
        }
        for marker in players {
            add("player-" + marker.id, marker.label, marker.position, y: marker.y, anchor: marker.anchor,
                frame: frame(.player(marker.kind), at: marker.anchor), target: .row(.player(marker.playerID)))
        }
        for place in savedPlaces {
            add("saved-" + place.id.uuidString, place.name, place.position, anchor: place.mapPosition,
                frame: frame(.savedPlace, at: place.mapPosition), target: .row(.savedPlace(place.id)))
        }
        return locations
    }

    /// Hit tests only drawn markers. Match drawing order for overlapping badges, preserving a
    /// portal's priority over a creature standing in it. Names are not prepared for hit testing.
    func target(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapTarget? {
        hit(at: point, viewport: viewport, size: size)?.target
    }

    func hit(at point: CGPoint, viewport: MapViewport, size: CGSize) -> MapHit? {
        func nearest<Item>(_ items: some Sequence<Item>, within reach: (Item) -> CGFloat,
                           position: (Item) -> CGPoint) -> Item? {
            var best: Item?
            var distance = CGFloat.infinity
            for item in items {
                let location = viewport.viewPoint(for: position(item), in: size)
                let candidate = hypot(location.x - point.x, location.y - point.y)
                if candidate <= reach(item), candidate <= distance { best = item; distance = candidate }
            }
            return best
        }
        if let place = nearest(savedPlaces, within: { _ in MarkerGeometry.savedPlace.hitRadius }, position: \.mapPosition) {
            return MapHit(target: .row(.savedPlace(place.id)), position: place.position)
        }
        if let player = nearest(players, within: { MarkerGeometry.player($0.kind).hitRadius }, position: \.anchor) {
            return MapHit(target: .row(.player(player.playerID)), position: player.position, y: player.y)
        }
        if let hit = nearest(hits.lazy.filter { $0.position != nil },
                             within: { MarkerGeometry.search(selected: $0.id == selectedHitID).hitRadius }, position: { $0.position! }) {
            return MapHit(target: .searchHit(hit.id), position: hit.position!, y: hit.y.map(Double.init))
        }
        let reach = max(MarkerGeometry.place(isPortal: true).hitRadius, MarkerGeometry.creature(selected: true).hitRadius)
        let bounds = CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
        let places = nearbyPlaces(viewport: viewport, size: size, bounds: bounds)
        if let portal = nearest(places.lazy.filter { $0.portal != nil }, within: { _ in MarkerGeometry.place(isPortal: true).hitRadius }, position: \.position) {
            return MapHit(target: .row(.place(portal.id)), position: portal.position, y: Double(portal.y))
        }
        if let creature = nearest(nearbyCreatures(viewport: viewport, size: size, bounds: bounds),
                                  within: { MarkerGeometry.creature(selected: selection == .creature($0)).hitRadius }, position: \.position) {
            return MapHit(target: .row(.creature(creature.id)), position: creature.position, y: creature.creature.y)
        }
        if let place = nearest(places, within: { MarkerGeometry.place(isPortal: $0.group == .portal).hitRadius }, position: \.position) {
            return MapHit(target: .row(.place(place.id)), position: place.position, y: Double(place.y))
        }
        if let structure = nearest(structures, within: { _ in MarkerGeometry.structure.hitRadius }, position: \.position) {
            return MapHit(target: .row(.structure(structure.id)), position: structure.position, y: structure.y.map(Double.init))
        }
        // Biomes draw areas, not badges at their representative position. They remain available
        // through the sidebar and accessibility locations without an invisible pointer target.
        return nil
    }
}

extension MapContent {
    /// A value projected from live document models, without retaining the document or a cache.
    init(session: WorldSession) {
        self.init()
        guard session.map != nil, let id = session.selectedDimensionID else { return }
        let index = session.presentation.selectedIndex
        heatMap = session.heatMap.visibleImages ?? [:]
        slimeChunks = session.slimeChunks.visibleImages
        slimeSeed = session.slimeChunks.visibleSeed
        if case .inGameMap(let item)? = session.selection.mapSelection, let image = session.selection.image(for: item) {
            inGameMap = (item, image, session.selection.inGameMapOpacity)
        }
        biomeAreas = index.biomeAreas.filter { session.visibility.biomes.contains($0.group) }
        biomes = index.biomes
        caveBiomes = index.caveBiomes
        border = session.details.borders[id].flatMap { $0.isLimited ? $0 : nil }
        showsGrid = session.visibility.showsGrid
        structures = index.structures.filter { session.visibility.structures.contains($0.group) }
        placePoints = index.placePoints
        shownPlaceGroups = session.visibility.places
        creaturePoints = index.creaturePoints
        shownCreatureGroups = session.visibility.creatures
        hits = session.search.pinnedHits(where: session.presentation.lists).filter { $0.dimension == id && $0.position != nil }
        selectedHitID = session.selection.selectedHitID
        players = session.presentation.drawnPlayerMarkers
        selection = session.selection.mapSelection
        selectedItem = session.selection.sidebarSelection
        selectedPlayerID = if case .player(let uuid)? = session.selection.inspector { uuid } else { nil }
        savedPlaces = session.savedPlaces.all.filter { $0.dimension == id }
        ruler = session.annotations.ruler
    }
}
