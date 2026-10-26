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
    let playerRecords: PlayerRecordsModel
    private var selectedItem: SidebarItem?
    private var inspectorIsShown = false
    /// A map can remain under a selected location while its inspector shows that location.
    private var overlayID: Int?
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]
    /// Inspector commands and linked-pet jumps can reveal an already-selected row again.
    private(set) var sidebarRevealRequest: UUID?
    var inGameMapOpacity = 0.85

    init(source: WorldSession) {
        self.source = source
        playerRecords = PlayerRecordsModel(world: source.world, work: source.resources.backgroundWork)
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
            if newValue != nil { revealSelectedRow() }
        }
    }

    var sidebarSelection: SidebarItem? {
        guard let source, let item = selectedItem, resolve(item) != nil else { return nil }
        if case .player(let id) = item, !source.presentation.listedPlayers.contains(where: { $0.uuid == id }) { return nil }
        return item
    }

    var selectedHitID: SearchHit.ID? {
        if case .hit(_, let id)? = sidebarSelection { return id }
        return nil
    }

    /// The inspector and overlay resolve independently from the same selected identity.
    var inspectorItem: ResolvedSidebarItem? {
        guard inspectorIsShown else { return nil }
        if let resolved = selectedItem.flatMap(resolve) { return detailItem(resolved) ?? resolved }
        if case .inGameMap(let map)? = mapSelection { return .inGameMap(map) }
        return nil
    }

    var selectedSearchHit: SearchHit? {
        guard inspectorIsShown, case .hit(let hit)? = selectedItem.flatMap(resolve) else { return nil }
        return hit
    }

    var mapSelection: MapSelection? {
        guard inspectorIsShown, let source else { return nil }
        switch detailItem(selectedItem.flatMap(resolve)) {
        case .creature(let marker)?: return .creature(marker)
        case .place(let marker)?:
            if let portal = marker.portal { return .portal(portal) }
        default: break
        }
        guard let overlayID, let map = source.presentation.inGameMaps.first(where: { $0.id == overlayID }), source.presentation.canShow(map) else { return nil }
        return .inGameMap(map)
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
        case .creature(let id): return index.creatures.first { $0.id == id }.map(ResolvedSidebarItem.creature)
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
        guard let source, !source.isClosed else { return }
        if item == nil, preservingGlobalRows {
            if selectedItem == .worldInfo || selectedItem == .storage { return }
            if case .inGameMap(let id)? = selectedItem, overlayID == id { return }
        }
        let previous = inspector
        let resolved = item.flatMap(resolve)
        selectedItem = resolved == nil ? nil : item
        switch detailItem(resolved) {
        case .worldInfo?, .storage?, .player?, .creature?: overlayID = nil
        case .place(let marker)?:
            if marker.portal != nil { overlayID = nil }
        case .inGameMap(let map)?: overlayID = map.id
        case .savedPlace?, .structure?, .biome?, .hit?, nil: break
        }
        inspectorIsShown = true
        if resolved != nil { followHeight(height) }
        if inspector != previous { playerRecords.cancel() }
    }

    /// Only sidebar input navigates and reveals a hidden layer; map input keeps focus/viewport.
    func choose(_ item: SidebarItem?) {
        guard let source, !source.isClosed else { return }
        guard let item, let resolved = resolve(item) else { select(nil); return }
        switch resolved {
        case .worldInfo, .storage: break
        case .savedPlace(let place):
            if source.annotations.canVisit(place) { source.annotations.visit(place) }
        case .structure(let marker):
            source.visibility.structures.insert(marker.group)
            source.navigation.focus(on: marker.position)
        case .place(let marker):
            source.visibility.places.insert(marker.group)
            source.navigation.focus(on: marker.position)
        case .creature(let marker):
            source.visibility.creatures.insert(marker.group)
            source.navigation.focus(on: marker.position)
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
            if case .layer(let layer, _) = hit.source {
                switch layer {
                case .structure(let group): source.visibility.structures.insert(group)
                case .place(let group): source.visibility.places.insert(group)
                case .creature(let group): source.visibility.creatures.insert(group)
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
            case .savedPlace, .structure, .place, .creature, .biome, .hit:
                item = resolve(row) == nil ? nil : row
            case .worldInfo, .storage, .inGameMap: item = nil
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
        if let image = inGameMapImages[map.id] { return image }
        let image = InGameMapImage.make(map)
        inGameMapImages[map.id] = image
        return image
    }

    func show(_ map: MapItem) {
        // Never draw a map from a missing dimension over another dimension's terrain.
        guard let source, source.presentation.canShow(map), let dimension = map.dimension else { return }
        if source.routing.route(to: dimension, perform: { $0.selection.show(map) }) { return }
        source.navigation.focus(on: CGPoint(x: map.centerX, y: map.centerZ))
        select(.inGameMap(map.id))
    }

    func close() { playerRecords.close() }
    func waitForReads() async { await playerRecords.waitForReads() }
}
