import ChunkseeIndex
import ChunkseeKit
import Foundation

enum SidebarSection: Hashable {
    case searchResults, world, savedSearches, structures, places, creatures, mobs, biomes, inGameMaps, players
}

/// Disclosure state belongs to this dimension's view. Revealing a marker opens just its ancestors.
struct SidebarDisclosure {
    var collapsedSections: Set<SidebarSection> = []
    var structures: Set<StructureGroup> = []
    var places: Set<PlaceGroup> = []
    var creatures: Set<CreatureGroup> = []
    var mobTypes: Set<String> = []
    var biomes: Set<BiomeGroup> = []
    var savedSearches: Set<UUID> = []
    var showsSavedPlaces = true

    /// The view and tests share this complete map-origin selection/reveal action.
    @discardableResult mutating func selectOnMap(_ target: MapTarget?, y: Double?, in session: WorldSession) -> Bool {
        guard let item = session.selection.mapClicked(target, y: y) else { return false }
        reveal(item, in: session)
        return true
    }

    mutating func reveal(_ item: SidebarItem, in session: WorldSession) {
        switch session.selection.resolve(item) {
        case .structure(let marker)?:
            collapsedSections.remove(.structures)
            structures.insert(marker.group)
        case .place(let marker)?:
            collapsedSections.remove(.places)
            places.insert(marker.group)
        case .creature(let marker)?:
            if case .mobCreature = item {
                collapsedSections.remove(.mobs)
                mobTypes.insert(marker.creature.id)
            } else if marker.group == .mob {
                collapsedSections.remove(.mobs)
                mobTypes.insert(marker.creature.id)
            } else {
                collapsedSections.remove(.creatures)
                creatures.insert(marker.group)
            }
        case .mobType?: collapsedSections.remove(.mobs)
        case .biome(let marker)?:
            collapsedSections.remove(.biomes)
            biomes.insert(marker.group)
        case .hit?:
            guard case .hit(let query, _) = item else { return }
            if session.search.isActive && query == session.search.text {
                collapsedSections.remove(.searchResults)
            } else if let saved = session.savedSearches.all.first(where: { $0.query == query }) {
                collapsedSections.remove(.savedSearches)
                savedSearches.insert(saved.id)
            }
        case .inGameMap?: collapsedSections.remove(.inGameMaps)
        case .savedPlace?:
            collapsedSections.remove(.places)
            showsSavedPlaces = true
        case .player?: collapsedSections.remove(.players)
        case .worldInfo?, .storage?: collapsedSections.remove(.world)
        case nil: break
        }
    }
}
