import CoreGraphics
import Foundation
import ChunkseeKit

/// A player's position, last death or respawn point on the map.
nonisolated struct MapMarker: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case player, death, respawn
    }

    var id: String
    var playerID: UUID
    var kind: Kind
    /// World X/Z of the marker.
    var position: CGPoint
    var y: Double?
    var label: String
    /// Entity positions are exact; death and respawn positions identify whole blocks. Drawing,
    /// picking and VoiceOver share this anchor, while copying retains the saved coordinates.
    var anchor: CGPoint { kind == .player ? position : CGPoint(x: position.x + 0.5, y: position.y + 0.5) }
    /// True when the player's file predates the world's current version: they haven't been seen
    /// since, so the position is old.
    var isOutdated: Bool
}

/// Presentation of players: names, notes, and which markers belong on a dimension's map.
nonisolated enum PlayerPresentation {
    enum Name: Equatable, Sendable {
        case you
        case named(String)

        var text: String {
            switch self {
            case .you: String(localized: "You")
            case .named(let name): name
            }
        }

        var inventory: String {
            switch self {
            case .you: String(localized: "Your inventory")
            case .named(let name): String(localized: "\(name)’s inventory")
            }
        }

        var enderChest: String {
            switch self {
            case .you: String(localized: "Your ender chest")
            case .named(let name): String(localized: "\(name)’s ender chest")
            }
        }

        var respawn: String {
            switch self {
            case .you: String(localized: "Your respawn point")
            case .named(let name): String(localized: "\(name)’s respawn point")
            }
        }

        var lastDeath: String {
            switch self {
            case .you: String(localized: "Where you last died")
            case .named(let name): String(localized: "Where \(name) last died")
            }
        }
    }

    /// A player's name when one is known (Minecraft's name caches or Mojang). Player files hold
    /// only UUIDs, so otherwise the singleplayer player is "You" and others are named by the start
    /// of their UUID.
    static func name(of player: PlayerInfo, singleplayerUUID: UUID?, knownName: String? = nil) -> String {
        label(of: player, singleplayerUUID: singleplayerUUID, knownName: knownName).text
    }

    /// Retain the personal pronoun separately from an account whose actual name is "You".
    static func label(of player: PlayerInfo, singleplayerUUID: UUID?, knownName: String? = nil) -> Name {
        if let knownName { return .named(knownName) }
        if player.uuid == singleplayerUUID { return .you }
        let short = player.uuid.uuidString.lowercased().prefix(8)
        return .named(String(localized: "Player \(String(short))"))
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

    static func position(of player: PlayerInfo) -> PlayerInfo.Location? {
        guard isMappable(player), let location = player.position,
              Coordinates.canLocate(x: location.x, y: location.y, z: location.z) else { return nil }
        return location
    }

    /// The players a dimension's sidebar lists: those last seen in it. Players with no usable
    /// position in this world are listed in its first dimension, the Overworld, so each player
    /// is listed once.
    static func listed(_ players: [PlayerInfo], in dimensionID: String, dimensions: [String]) -> [PlayerInfo] {
        players.filter { player in
            if let position = position(of: player), dimensions.contains(position.dimension) {
                return position.dimension == dimensionID
            }
            return dimensionID == dimensions.first
        }
    }

    /// Markers for one dimension: each mappable player's last position, last death and respawn point.
    static func markers(for players: [PlayerInfo], in dimensionID: String, singleplayerUUID: UUID?,
                        worldDataVersion: Int?, knownName: (UUID) -> String? = { _ in nil }) -> [MapMarker] {
        var markers: [MapMarker] = []
        for player in players where isMappable(player) {
            let name = label(of: player, singleplayerUUID: singleplayerUUID, knownName: knownName(player.uuid))
            let outdated = isOutdated(player, worldDataVersion: worldDataVersion)
            let id = player.uuid.uuidString
            func add(_ kind: MapMarker.Kind, _ location: PlayerInfo.Location?, _ label: String) {
                guard let location, location.dimension == dimensionID,
                      Coordinates.canLocate(x: location.x, y: location.y, z: location.z) else { return }
                markers.append(MapMarker(id: "\(id)-\(kind)", playerID: player.uuid, kind: kind, position: CGPoint(x: location.x, y: location.z),
                                         y: location.y, label: label, isOutdated: outdated))
            }
            add(.respawn, player.respawn, name.respawn)
            add(.death, player.lastDeath, name.lastDeath)
            add(.player, player.position, name.text)
        }
        return markers
    }
}
