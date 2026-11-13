import ChunkseeIndex
import CoreGraphics
import Foundation
import ChunkseeKit
import Observation

/// One dimension document's selected identity, inspector and retained in-game map overlay.
/// Live world data supplies the details; selection never keeps an old marker snapshot.
@Observable
final class SelectionModel {
    @ObservationIgnored private weak var source: WorldSession?
    private(set) var playerRecords: PlayerRecordStore.Handle?
    private var isClosed = false
    @ObservationIgnored private var selectionObservation: ModelObservation?
    private var selectedItem: SidebarItem?
    private var inspectorIsShown = false
    /// A map can remain under a selected location while its inspector shows that location.
    private var overlayID: Int?
    @ObservationIgnored private var inGameMapImages = InGameMapImage.Cache()
    /// Inspector commands and linked-pet jumps can reveal an already-selected row again.
    private(set) var sidebarRevealRequest: UUID?
    var inGameMapOpacity = 0.85

    init(source: WorldSession) {
        self.source = source
        observeSelection()
    }

    /// Showing details again keeps the chosen identity and never navigates the map.
    var isInspectorShown: Bool {
        get { inspector != nil }
        set {
            InspectorBindingTrace.record("selection.visibility.request", session: source, requested: newValue)
            defer { InspectorBindingTrace.record("selection.visibility.result", session: source, requested: newValue) }
            guard let source, !source.isClosed else { return }
            if newValue, selectedItem.flatMap(resolve) == nil, inGameMapOverlay == nil {
                select(.worldInfo)
            } else {
                inspectorIsShown = newValue
            }
            if newValue { revealSelectedRow() }
        }
    }

    var inspector: Inspector? {
        get {
            guard inspectorIsShown else { return nil }
            switch inspectorItem {
            case .worldInfo?: return .world
            case .storage?: return .storage
            case .player(let player)?: return .player(player.uuid)
            case nil: return nil
            default: return .selection
            }
        }
        set {
            guard source?.isClosed == false else { return }
            switch newValue {
            case .world?: select(.worldInfo)
            case .storage?: select(.storage)
            case .player(let id)?: select(.player(id))
            case .selection?: isInspectorShown = true; return
            case nil: isInspectorShown = false; return
            }
            revealSelectedRow()
        }
    }

    var sidebarSelection: SidebarItem? {
        guard let source, let item = selectedItem, resolve(item) != nil else { return nil }
        if case .player(let id) = item, !source.presentation.listedPlayers.contains(where: { $0.uuid == id }) { return nil }
        return item
    }

    /// The inspector and overlay resolve independently from the same selected identity.
    var inspectorItem: ResolvedSidebarItem? {
        guard inspectorIsShown else { return nil }
        if let resolved = selectedItem.flatMap(resolve) { return detailItem(resolved) ?? resolved }
        if let map = inGameMapOverlay { return .inGameMap(map) }
        return nil
    }

    var selectedSearchHit: SearchHit? {
        guard inspectorIsShown, case .hit(let hit)? = selectedItem.flatMap(resolve) else { return nil }
        return hit
    }

    var inGameMapOverlay: MapItem? {
        guard let source else { return nil }
        guard let overlayID, let map = source.presentation.inGameMaps.first(where: { $0.id == overlayID }), source.presentation.canShow(map) else { return nil }
        return map
    }

    /// Map drawing receives identities, independent of whether the inspector is visible.
    /// A search pin and the live item it resolves to share the selected treatment.
    var highlighted: Set<MapTarget> {
        guard let resolved = selectedItem.flatMap(resolve) else { return [] }
        var targets: Set<MapTarget> = []
        if case .hit(let hit) = resolved { targets.insert(.searchHit(hit.id)) }
        switch detailItem(resolved) {
        case .savedPlace(let place)?: targets.insert(.row(.savedPlace(place.id)))
        case .structure(let marker)?: targets.insert(.row(.structure(marker.id)))
        case .place(let marker)?: targets.insert(.row(.place(marker.id)))
        case .creature(let selection)?:
            // Both sidebar rows identify the same drawn creature; picking keeps its row route.
            targets.insert(.row(.creature(selection.marker.id)))
            targets.insert(.row(.mobCreature(selection.marker.id)))
        case .biome(let area)?: targets.insert(.row(.biome(area.id)))
        case .player(let player)?: targets.insert(.row(.player(player.uuid)))
        case .worldInfo?, .storage?, .mobType?, .inGameMap?, .hit?, nil: break
        }
        return targets
    }

    /// Resolves every selectable identity without retaining the world or a data snapshot.
    func resolve(_ item: SidebarItem) -> ResolvedSidebarItem? {
        guard let source else { return nil }
        let index = source.presentation.selectedIndex
        switch item {
        case .worldInfo: return .worldInfo
        case .storage: return .storage
        case .savedPlace(let id): return source.annotations.listedPlaces.first { $0.id == id }.map(ResolvedSidebarItem.savedPlace)
        case .structure(let id): return index.structures.first { $0.id == id }.map(ResolvedSidebarItem.structure)
        case .place(let id): return index.places.first { $0.id == id }.map(ResolvedSidebarItem.place)
        case .creature(let id), .mobCreature(let id):
            return index.mobTypes.marker(id).map { .creature(CreatureSelection($0, selectedRow: item)) }
        case .mobType(let id): return index.mobTypes.kind(id).map(ResolvedSidebarItem.mobType)
        case .biome(let id): return index.biomeAreas.first { $0.id == id }.map(ResolvedSidebarItem.biome)
        case .inGameMap(let id): return source.presentation.inGameMaps.first { $0.id == id }.map(ResolvedSidebarItem.inGameMap)
        case .player(let id): return source.players.first { $0.uuid == id }.map(ResolvedSidebarItem.player)
        case .hit(let query, let id):
            guard (source.search.isActive && query == source.search.text) || source.savedSearches.contains(query) else { return nil }
            return source.search.listedHits(for: query, where: source.presentation.lists).rows.first { $0.id == id }.map(ResolvedSidebarItem.hit)
        }
    }

    /// Keep the selected search row, but resolve its entity through the same live-data owner.
    private func detailItem(_ resolved: ResolvedSidebarItem?) -> ResolvedSidebarItem? {
        guard case .hit(let hit)? = resolved else { return resolved }
        switch hit.source {
        case .inventory(let id), .enderChest(let id): return resolve(.player(id))
        case .layer(let layer, let id):
            guard hit.dimension == source?.selectedDimensionID else { return nil }
            switch layer {
            case .structure: return resolve(.structure(id))
            case .place: return resolve(.place(id))
            case .creature: return resolve(.creature(id))
            case .biome: return resolve(.biome(id))
            }
        case .container, .sign, .block: return resolved
        }
    }

    /// Every input path changes this identity. Overlay retention is independent of the row.
    private func select(_ item: SidebarItem?, height: Int? = nil, preservingGlobalRows: Bool = false) {
        defer { InspectorBindingTrace.record("selection.select.result", session: source) }
        guard let source, !source.isClosed else { return }
        if item == nil, preservingGlobalRows {
            if selectedItem == .worldInfo || selectedItem == .storage { return }
            if case .inGameMap(let id)? = selectedItem, overlayID == id { return }
        }
        let resolved = item.flatMap(resolve)
        selectedItem = resolved == nil ? nil : item
        switch detailItem(resolved) {
        case .worldInfo?, .storage?, .player?, .creature?, .mobType?: overlayID = nil
        case .place(let marker)?:
            if marker.portal != nil { overlayID = nil }
        case .inGameMap(let map)?: overlayID = map.id
        case .savedPlace?, .structure?, .biome?, .hit?, nil: break
        }
        // Clearing a selection must not reopen hidden details for a retained map.
        if resolved != nil {
            inspectorIsShown = true
            followHeight(height)
        }
    }

    /// Only sidebar input navigates and reveals a hidden layer; map input keeps focus/viewport.
    func choose(_ item: SidebarItem?) {
        guard let source, !source.isClosed else { return }
        guard let item, let resolved = resolve(item) else { select(nil); return }
        switch resolved {
        case .worldInfo, .storage: break
        case .mobType(let kind): source.visibility.mobTypes.insert(kind.id)
        case .savedPlace(let place):
            if source.annotations.canVisit(place) { source.annotations.visit(place) }
        case .structure(let marker):
            source.visibility.structures.insert(marker.group)
            source.navigation.focus(on: marker.position)
        case .place(let marker):
            source.visibility.places.insert(marker.group)
            source.navigation.focus(on: marker.position)
        case .creature(let selection):
            source.visibility.reveal(selection)
            source.navigation.focus(on: selection.marker.position)
        case .biome(let area):
            source.visibility.biomes.insert(area.group)
            source.navigation.focus(on: area.position)
        case .inGameMap(let map):
            if source.presentation.canShow(map) { show(map) }
        case .player(let player):
            source.visibility.hiddenPlayers.remove(player.uuid)
            if source.routing.canFocus(player), let location = player.position {
                focus(on: CGPoint(x: location.x, y: location.z),
                      height: BlockPosition.coordinate(containing: location.y), in: location.dimension)
            }
        case .hit(let hit):
            if case .hit(let query, _) = item,
               let saved = source.savedSearches.all.first(where: { $0.query == query && !$0.isShown }) {
                source.savedSearches.setShown(saved.id, true)
            }
            if let dimension = hit.dimension, let position = hit.position {
                focus(on: position, height: hit.y, in: dimension)
            }
            if case .layer(let layer, let markerID) = hit.source {
                switch layer {
                case .structure(let group): source.visibility.structures.insert(group)
                case .place(let group): source.visibility.places.insert(group)
                case .creature:
                    if let dimension = hit.dimension,
                       let marker = source.search.index.dimensions[dimension]?.mobTypes.marker(markerID) {
                        source.visibility.reveal(CreatureSelection(marker, selectedRow: item))
                    }
                case .biome(let group): source.visibility.biomes.insert(group)
                }
            }
        }
        select(item, height: resolved.height(in: source.selectedDimensionID))
    }

    /// Repeating a sidebar action uses today's saved location and the original navigation path.
    func repeatSelection(_ item: SidebarItem) {
        guard sidebarSelection == item else { return }
        choose(item)
    }

    /// A death/respawn marker may show player details here when their row belongs elsewhere.
    @discardableResult func mapClicked(_ clicked: MapTarget?, y: Double?) -> SidebarItem? {
        let item: SidebarItem?
        switch clicked {
        case .searchHit(let id)?: item = searchRow(for: id)
        case .row(let row)?:
            switch row {
            case .player(let id): item = source?.presentation.drawnPlayerMarkers.contains { $0.playerID == id } == true ? row : nil
            case .savedPlace, .structure, .place, .creature, .mobCreature, .biome, .hit:
                item = resolve(row) == nil ? nil : row
            case .worldInfo, .storage, .inGameMap, .mobType: item = nil
            }
        case nil: item = nil
        }
        select(item, height: y.flatMap(BlockPosition.coordinate(containing:)), preservingGlobalRows: true)
        return item == nil ? nil : sidebarSelection
    }

    /// Selection changes height once; a later save or manual slider change does not track the item.
    private func followHeight(_ height: Int?) {
        guard let height, let map = source?.map else { return }
        map.setHeight(height)
    }

    private func focus(on position: CGPoint, height: Int?, in dimension: String) {
        guard let source, !source.isClosed, MapCoordinates(point: position) != nil else { return }
        if source.routing.route(to: dimension, perform: { $0.selection.focus(on: position, height: height, in: dimension) }) { return }
        source.navigation.focus(on: position)
        followHeight(height)
    }

    private func searchRow(for id: SearchHit.ID) -> SidebarItem? {
        guard let source else { return nil }
        for query in source.search.visibleSearchQueries where source.search.listedHits(for: query, where: source.presentation.lists).rows.contains(where: { $0.id == id }) {
            return .hit(query: query, id: id)
        }
        return nil
    }

    /// Resolve ownership again before dispatch; the destination document owns the selection.
    func showLinkedPet(_ pet: CreatureMarker, ownedBy playerID: UUID) {
        guard let source, !source.isClosed,
              let current = source.search.index.dimensions[pet.dimension]?.creatures.first(where: { $0.id == pet.id && $0.creature.owner == playerID }) else { return }
        if source.routing.route(to: current.dimension, perform: { $0.selection.showLinkedPet(current, ownedBy: playerID) }) { return }
        choose(.creature(current.id))
        revealSelectedRow()
    }

    private func revealSelectedRow() {
        guard let source, !source.isClosed, sidebarSelection != nil else { return }
        sidebarRevealRequest = UUID()
    }

    func show(_ portal: NetherPortal) {
        guard let source else { return }
        if source.routing.route(to: portal.dimension, perform: { $0.selection.show(portal) }) { return }
        source.routing.focus(on: PlayerInfo.Location(dimension: portal.dimension, x: portal.centerX, y: Double(portal.minY), z: portal.centerZ))
        select(.place(PlaceMarker(portal).id), height: portal.minY)
    }

    /// An image cache for the sidebar thumbnail and the selected map overlay.
    func image(for map: MapItem) -> CGImage? {
        guard let publication = source?.details.mapImageSource(for: map.id), publication.map == map else {
            return InGameMapImage.make(map)
        }
        return inGameMapImages.image(for: publication)
    }

    func show(_ map: MapItem) {
        // Never draw a map from a missing dimension over another dimension's terrain.
        guard let source, source.presentation.canShow(map), let dimension = map.dimension else { return }
        if source.routing.route(to: dimension, perform: { $0.selection.show(map) }) { return }
        source.navigation.focus(on: CGPoint(x: map.centerX, y: map.centerZ))
        select(.inGameMap(map.id))
    }

    /// A removed identity must not return as a selected row after its inspector was dismissed.
    /// Hiding an inspector deliberately still preserves a selection that remains available.
    private func discardMissingSelection() {
        if let selectedItem, resolve(selectedItem) == nil {
            self.selectedItem = nil
            inspector = nil
            overlayID = nil
        }
        if let overlayID, resolve(.inGameMap(overlayID)) == nil {
            self.overlayID = nil
        }
    }

    /// Selection, including its live resolution, owns record demand even for hidden windows.
    private func observeSelection() {
        selectionObservation = ModelObservation(self, isActive: { !$0.isClosed }, read: {
            _ = $0.selectedItem.flatMap($0.resolve)
            if let overlayID = $0.overlayID { _ = $0.resolve(.inGameMap(overlayID)) }
            _ = $0.inspector
        }) { selection, _ in
            selection.discardMissingSelection()
            selection.updatePlayerRecords()
        }
    }

    private func updatePlayerRecords() {
        let uuid: UUID?
        if case .player(let selected) = inspector { uuid = selected } else { uuid = nil }
        guard uuid != playerRecords?.uuid else { return }
        playerRecords?.close()
        playerRecords = uuid.flatMap { source?.resources.playerRecords.acquire($0) }
    }

    func close() {
        selectionObservation?.cancel()
        isClosed = true
        playerRecords?.close()
        playerRecords = nil
    }
}
