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
    /// A map can remain under a selected marker that has no details of its own.
    private var overlayID: Int?
    @ObservationIgnored private var inGameMapImages: [Int: CGImage] = [:]
    /// Linked-pet jumps reveal an already-selected row after its group is collapsed again.
    private(set) var sidebarRevealRequest: UUID?
    var inGameMapOpacity = 0.85

    init(source: WorldSession) {
        self.source = source
        playerRecords = PlayerRecordsModel(world: source.world, work: source.resources.backgroundWork)
    }

    var inspector: Inspector? {
        get {
            guard inspectorIsShown else { return nil }
            switch selectedItem.flatMap(resolve) {
            case .worldInfo?: return .world
            case .storage?: return .storage
            case .player(let player)?: return .player(player.uuid)
            default: return mapSelection == nil ? nil : .selection
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
        guard let source, let item = selectedItem, resolve(item) != nil else { return nil }
        if case .player(let id) = item, !source.presentation.listedPlayers.contains(where: { $0.uuid == id }) { return nil }
        return item
    }

    var selectedHitID: SearchHit.ID? {
        if case .hit(_, let id)? = sidebarSelection { return id }
        return nil
    }

    var mapSelection: MapSelection? {
        guard inspectorIsShown, let source else { return nil }
        switch selectedItem.flatMap(resolve) {
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

    /// Every input path changes this identity. Overlay retention is independent of the row.
    private func select(_ item: SidebarItem?, preservingGlobalRows: Bool = false) {
        guard let source, !source.isClosed else { return }
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

    /// Only sidebar input navigates and reveals a hidden layer; map input keeps focus/viewport.
    func choose(_ item: SidebarItem?) {
        guard let source, !source.isClosed else { return }
        guard let item, let resolved = resolve(item) else { select(nil); return }
        switch resolved {
        case .worldInfo, .storage: break
        case .savedPlace(let place):
            guard source.annotations.canVisit(place) else { return }
            source.annotations.visit(place)
        case .structure(let marker):
            source.visibility.structures.insert(marker.group)
            source.navigation.focus(on: marker.position, keepingZoom: true)
        case .place(let marker):
            source.visibility.places.insert(marker.group)
            source.navigation.focus(on: marker.position, keepingZoom: true)
        case .creature(let marker):
            source.visibility.creatures.insert(marker.group)
            source.navigation.focus(on: marker.position, keepingZoom: true)
        case .biome(let area):
            source.visibility.biomes.insert(area.group)
            source.navigation.focus(on: area.position, keepingZoom: true)
        case .inGameMap(let map):
            guard source.presentation.canShow(map) else { return }
            show(map, keepingZoom: true)
        case .player(let player):
            source.visibility.hiddenPlayers.remove(player.uuid)
            if source.routing.canFocus(player), let position = player.position { source.routing.focus(on: position, keepingZoom: true) }
        case .hit(let hit):
            guard let dimension = hit.dimension, let position = hit.position else { return }
            source.routing.focus(on: PlayerInfo.Location(dimension: dimension, x: position.x, y: Double(hit.y ?? 64), z: position.y), keepingZoom: true)
            if case .layer(let layer) = hit.source {
                switch layer {
                case .structure(let group): source.visibility.structures.insert(group)
                case .place(let group): source.visibility.places.insert(group)
                case .creature(let group): source.visibility.creatures.insert(group)
                case .biome(let group): source.visibility.biomes.insert(group)
                }
            }
        }
        select(item)
    }

    /// A death/respawn marker may show player details here when their row belongs elsewhere.
    @discardableResult func mapClicked(_ clicked: MapTarget?) -> SidebarItem? {
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
        select(item, preservingGlobalRows: true)
        return item == nil ? nil : sidebarSelection
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
        sidebarRevealRequest = UUID()
    }

    func show(_ portal: NetherPortal, keepingZoom: Bool = false) {
        guard let source else { return }
        if source.routing.route(to: portal.dimension, perform: { $0.selection.show(portal, keepingZoom: keepingZoom) }) { return }
        source.routing.focus(on: PlayerInfo.Location(dimension: portal.dimension, x: portal.centerX, y: Double(portal.minY), z: portal.centerZ),
                     keepingZoom: keepingZoom)
        select(.place(PlaceMarker(portal).id))
    }

    /// An image cache for the sidebar thumbnail and the selected map overlay.
    func image(for map: MapItem) -> CGImage? {
        if let image = inGameMapImages[map.id] { return image }
        let image = InGameMapImage.make(map)
        inGameMapImages[map.id] = image
        return image
    }

    func show(_ map: MapItem, keepingZoom: Bool = false) {
        // Never draw a map from a missing dimension over another dimension's terrain.
        guard let source, source.presentation.canShow(map), let dimension = map.dimension else { return }
        if source.routing.route(to: dimension, perform: { $0.selection.show(map, keepingZoom: keepingZoom) }) { return }
        source.navigation.focus(on: CGPoint(x: map.centerX, y: map.centerZ), keepingZoom: keepingZoom,
                                fittingScale: InGameMapImage.fittingScale(for: map))
        select(.inGameMap(map.id))
    }

    func close() { playerRecords.close() }
    func waitForReads() async { await playerRecords.waitForReads() }
}
