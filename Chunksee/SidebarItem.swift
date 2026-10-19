import ChunkseeKit
import Foundation

/// What the inspector beside the map shows.
enum Inspector: Equatable {
    case world
    case storage
    case player(UUID)
    /// The portal, creature or in-game map selected on the map.
    case selection
}

/// A sidebar row that can be selected. Choosing it shows its item: World Info and Storage in the
/// inspector, everything else on the map.
enum SidebarItem: Hashable {
    case worldInfo
    case storage
    case savedPlace(UUID)
    case structure(String)
    case place(String)
    case creature(String)
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

/// The thing selected on the map, whose details the inspector shows; one at a time.
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
    case biome(BiomeArea)
    case inGameMap(MapItem)
    case player(PlayerInfo)
    case hit(SearchHit)
}
