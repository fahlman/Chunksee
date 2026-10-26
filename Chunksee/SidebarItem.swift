import ChunkseeKit
import Foundation

/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
    case storage
    case player(UUID)
    /// The selected location's details, including a retained in-game map when no row is selected.
    case selection
}

/// A sidebar row that can be selected. Every item opens its inspector; a usable location also
/// centers the map when chosen in the sidebar.
nonisolated enum SidebarItem: Hashable, Sendable {
    case worldInfo
    case storage
    case savedPlace(UUID)
    case structure(String)
    case place(String)
    case creature(String)
    case mobType(String)
    /// The same saved creature has a distinct row identity in its type's disclosure.
    case mobCreature(String)
    case biome(String)
    case inGameMap(Int)
    case player(UUID)
    /// A search result, under the query that found it: the search bar's or a saved search's.
    case hit(query: String, id: String)
}

/// A drawn location identifies its sidebar row, or a search hit whose query the session resolves.
enum MapTarget: Equatable {
    case row(SidebarItem)
    case searchHit(SearchHit.ID)
}

/// Highlighted creature/portal or retained map overlay; the inspector resolves its item separately.
enum MapSelection: Equatable {
    case portal(NetherPortal)
    case creature(CreatureMarker)
    case inGameMap(MapItem)

    var dimension: String? {
        switch self {
        case .portal(let portal): portal.dimension
        case .creature(let creature): creature.dimension
        case .inGameMap(let map): map.dimension
        }
    }
}

/// Current data for a sidebar identity. Selection resolves it again after a live update.
enum ResolvedSidebarItem {
    case worldInfo
    case storage
    case savedPlace(SavedPlace)
    case structure(StructureMarker)
    case place(PlaceMarker)
    case creature(CreatureMarker)
    case mobType(MobTypes.Kind)
    case biome(BiomeArea)
    case inGameMap(MapItem)
    case player(PlayerInfo)
    case hit(SearchHit)
}

extension ResolvedSidebarItem {
    /// Only a saved location in this dimension can supply its selected cutaway height.
    func height(in dimension: String?) -> Int? {
        switch self {
        case .structure(let marker): return marker.y
        case .place(let marker): return marker.y
        case .creature(let marker): return BlockPosition.coordinate(containing: marker.creature.y)
        case .player(let player):
            guard let location = PlayerPresentation.position(of: player), location.dimension == dimension else { return nil }
            return BlockPosition.coordinate(containing: location.y)
        case .hit(let hit): return hit.dimension == dimension ? hit.y : nil
        case .worldInfo, .storage, .savedPlace, .biome, .inGameMap, .mobType: return nil
        }
    }
}
