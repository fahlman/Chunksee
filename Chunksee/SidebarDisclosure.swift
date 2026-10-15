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

    mutating func reveal(_ item: SidebarItem, in session: WorldSession) {
        let index = session.selectedIndex
        switch item {
        case .structure(let id):
            guard let marker = index.structures.first(where: { $0.id == id }) else { return }
            collapsedLayers.remove(.structures)
            structures.insert(marker.group)
        case .place(let id):
            guard let marker = index.places.first(where: { $0.id == id }) else { return }
            collapsedLayers.remove(.places)
            places.insert(marker.group)
        case .creature(let id):
            guard let marker = index.creatures.first(where: { $0.id == id }) else { return }
            collapsedLayers.remove(.creatures)
            creatures.insert(marker.group)
        case .biome(let id):
            guard let marker = index.biomeAreas.first(where: { $0.id == id }) else { return }
            collapsedLayers.remove(.biomes)
            biomes.insert(marker.group)
        case .hit(let query, _):
            if let saved = session.savedSearches.all.first(where: { $0.query == query }) {
                savedSearches.insert(saved.id)
            }
        case .inGameMap:
            showsInGameMaps = true
        default:
            break
        }
    }
}
