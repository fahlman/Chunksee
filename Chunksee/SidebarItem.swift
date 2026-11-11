import ChunkseeIndex
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
nonisolated enum MapTarget: Hashable, Sendable {
    case row(SidebarItem)
    case searchHit(SearchHit.ID)
}

/// A creature can appear in its special group and its mob type. Resolve that choice with the
/// live marker so disclosure, visibility and map picking preserve the same row route.
nonisolated struct CreatureSelection: Equatable, Sendable {
    enum List: Equatable, Sendable {
        case creatures(CreatureGroup)
        case mobs(String)
    }

    let marker: CreatureMarker
    let list: List

    init(_ marker: CreatureMarker, selectedRow: SidebarItem?) {
        self.marker = marker
        if marker.group == .mob || selectedRow == .mobCreature(marker.id) {
            list = .mobs(marker.creature.id)
        } else {
            list = .creatures(marker.group)
        }
    }

    var row: SidebarItem {
        switch list {
        case .creatures: .creature(marker.id)
        case .mobs: .mobCreature(marker.id)
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
    case creature(CreatureSelection)
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
        case .creature(let selection): return BlockPosition.coordinate(containing: selection.marker.creature.y)
        case .player(let player):
            guard let location = PlayerPresentation.position(of: player), location.dimension == dimension else { return nil }
            return BlockPosition.coordinate(containing: location.y)
        case .hit(let hit): return hit.dimension == dimension ? hit.y : nil
        case .worldInfo, .storage, .savedPlace, .biome, .inGameMap, .mobType: return nil
        }
    }
}
