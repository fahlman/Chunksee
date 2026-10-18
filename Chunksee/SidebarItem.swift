import ChunkseeKit
import Foundation

/// Current data for a sidebar identity. The session resolves it again after a live update.
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
