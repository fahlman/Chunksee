import CoreGraphics
import Foundation
import MCWorldKit

/// A point of interest drawn on the map.
nonisolated struct MapMarker: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case player, death, respawn
    }

    var id: String
    var kind: Kind
    /// World X/Z of the marker.
    var position: CGPoint
    var label: String
    /// True when the player's file predates the world's current version: they haven't been seen
    /// since, so the position is old.
    var isOutdated: Bool
}

/// Presentation of players: names, notes, and which markers belong on a dimension's map.
nonisolated enum PlayerPresentation {
    /// Player files hold only UUIDs, so players are named by the start of theirs; the singleplayer
    /// player is "You".
    static func name(of player: PlayerInfo, singleplayerUUID: UUID?) -> String {
        if player.uuid == singleplayerUUID { return String(localized: "You") }
        let short = player.uuid.uuidString.lowercased().prefix(8)
        return String(localized: "Player \(String(short))")
    }

    /// Whether the player hasn't joined since the world was last upgraded.
    static func isOutdated(_ player: PlayerInfo, worldDataVersion: Int?) -> Bool {
        guard let worldDataVersion else { return false }
        return (player.dataVersion ?? 0) < worldDataVersion
    }

    /// Whether the player's locations can be placed on this world's map. Bukkit servers share
    /// player files across worlds, so their positions may be somewhere else entirely.
    static func isMappable(_ player: PlayerInfo) -> Bool {
        !player.isFromBukkitServer
    }

    /// Markers for one dimension: each mappable player's last position, last death and respawn point.
    static func markers(for players: [PlayerInfo], in dimensionID: String,
                        singleplayerUUID: UUID?, worldDataVersion: Int?) -> [MapMarker] {
        var markers: [MapMarker] = []
        for player in players where isMappable(player) {
            let name = name(of: player, singleplayerUUID: singleplayerUUID)
            let outdated = isOutdated(player, worldDataVersion: worldDataVersion)
            let id = player.uuid.uuidString
            func add(_ kind: MapMarker.Kind, _ location: PlayerInfo.Location?, _ label: String) {
                guard let location, location.dimension == dimensionID else { return }
                markers.append(MapMarker(id: "\(id)-\(kind)", kind: kind, position: CGPoint(x: location.x, y: location.z),
                                         label: label, isOutdated: outdated))
            }
            add(.respawn, player.respawn, String(localized: "\(name)’s respawn point"))
            add(.death, player.lastDeath, String(localized: "Where \(name) last died"))
            add(.player, player.position, name)
        }
        return markers
    }
}
