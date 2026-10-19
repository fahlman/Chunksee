import ChunkseeKit
import Foundation

enum SidebarLayer: Hashable {
    case structures, places, creatures, biomes
}

/// Disclosure state belongs to this dimension's view. Revealing a marker opens just its ancestors.
struct SidebarDisclosure {
    var collapsedLayers: Set<SidebarLayer> = []
    var structures: Set<StructureGroup> = []
    var places: Set<PlaceGroup> = []
    var creatures: Set<CreatureGroup> = []
    var biomes: Set<BiomeGroup> = []
    var savedSearches: Set<UUID> = []
    var showsInGameMaps = false

    /// The view and tests share this complete map-origin selection/reveal action.
    @discardableResult mutating func selectOnMap(_ target: MapTarget?, y: Double?, in session: WorldSession) -> Bool {
        guard let item = session.selection.mapClicked(target, y: y) else { return false }
        reveal(item, in: session)
        return true
    }

    mutating func reveal(_ item: SidebarItem, in session: WorldSession) {
        switch session.selection.resolve(item) {
        case .structure(let marker)?:
            collapsedLayers.remove(.structures)
            structures.insert(marker.group)
        case .place(let marker)?:
            collapsedLayers.remove(.places)
            places.insert(marker.group)
        case .creature(let marker)?:
            collapsedLayers.remove(.creatures)
            creatures.insert(marker.group)
        case .biome(let marker)?:
            collapsedLayers.remove(.biomes)
            biomes.insert(marker.group)
        case .hit?:
            guard case .hit(let query, _) = item else { return }
            if let saved = session.savedSearches.all.first(where: { $0.query == query }) {
                savedSearches.insert(saved.id)
            }
        case .inGameMap?: showsInGameMaps = true
        case .worldInfo?, .storage?, .savedPlace?, .player?, nil: break
        }
    }
}
