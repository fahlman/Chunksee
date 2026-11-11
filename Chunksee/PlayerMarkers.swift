import CoreGraphics
import Foundation
import ChunkseeKit

/// A player's position, last death or respawn point on the map.
nonisolated struct MapMarker: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case player, death, respawn
    }

    var id: String
    var playerID: UUID
    var kind: Kind
    /// World X/Z of the marker.
    var position: CGPoint
    var y: Double?
    var name: GameNames.PlayerName
    /// Entity positions are exact; death and respawn positions identify whole blocks. Drawing,
    /// picking and VoiceOver share this anchor, while copying retains the saved coordinates.
    var anchor: CGPoint { kind == .player ? position : CGPoint(x: position.x + 0.5, y: position.y + 0.5) }
    /// True when the player's file predates the world's current version: they haven't been seen
    /// since, so the position is old.
    var isOutdated: Bool
}

/// Valid saved player locations, their age, and membership in a dimension's map.
nonisolated enum PlayerPresentation {
    /// Whether the player hasn't joined since the world was last upgraded.
    static func isOutdated(_ player: PlayerInfo, worldDataVersion: Int?) -> Bool {
        guard let worldDataVersion else { return false }
        return (player.dataVersion ?? 0) < worldDataVersion
    }

    /// Invalid saved coordinates stay unavailable. Whether a known dimension is openable
    /// remains the session's rule.
    private static func usable(_ location: PlayerInfo.Location?) -> PlayerInfo.Location? {
        guard let location, Coordinates.canLocate(x: location.x, y: location.y, z: location.z) else { return nil }
        return location
    }

    static func position(of player: PlayerInfo) -> PlayerInfo.Location? { usable(player.position) }

    struct Location: Identifiable, Sendable {
        let kind: MapMarker.Kind
        let position: PlayerInfo.Location
        var id: MapMarker.Kind { kind }
        var isBlockPosition: Bool { kind != .player }
    }

    /// The inspector and map consume the same valid saved locations.
    static func locations(of player: PlayerInfo) -> [Location] {
        let candidates: [(MapMarker.Kind, PlayerInfo.Location?)] = [
            (.player, player.position), (.death, player.lastDeath), (.respawn, player.respawn),
        ]
        return candidates.compactMap { kind, location in
            usable(location).map { Location(kind: kind, position: $0) }
        }
    }

    /// Markers for one dimension: each mappable player's last position, last death and respawn point.
    static func markers(for players: [PlayerInfo], in dimensionID: String, singleplayerUUID: UUID?,
                        worldDataVersion: Int?, knownName: (UUID) -> String? = { _ in nil }) -> [MapMarker] {
        var markers: [MapMarker] = []
        for player in players {
            let name = GameNames.PlayerName(playerID: player.uuid, singleplayerUUID: singleplayerUUID, knownName: knownName(player.uuid))
            let outdated = isOutdated(player, worldDataVersion: worldDataVersion)
            let id = player.uuid.uuidString
            // Keep the live-position badge last, matching the existing overlap priority.
            for saved in locations(of: player).reversed() where saved.position.dimension == dimensionID {
                let location = saved.position
                markers.append(MapMarker(id: "\(id)-\(saved.kind)", playerID: player.uuid, kind: saved.kind,
                                         position: CGPoint(x: location.x, y: location.z), y: location.y,
                                         name: name, isOutdated: outdated))
            }
        }
        return markers
    }
}
