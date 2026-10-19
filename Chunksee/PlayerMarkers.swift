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
        return .named(String(localized: "Player \(shortID(player.uuid))"))
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

    /// Keeps raw saved positions out of the UI when they are invalid or may belong to a
    /// different Bukkit world. Whether a known dimension is openable remains the session's rule.
    private static func usable(_ location: PlayerInfo.Location?, of player: PlayerInfo) -> PlayerInfo.Location? {
        guard isMappable(player), let location,
              Coordinates.canLocate(x: location.x, y: location.y, z: location.z) else { return nil }
        return location
    }

    static func position(of player: PlayerInfo) -> PlayerInfo.Location? { usable(player.position, of: player) }

    struct Location: Identifiable, Sendable {
        let kind: MapMarker.Kind
        let position: PlayerInfo.Location
        var id: MapMarker.Kind { kind }
        var isBlockPosition: Bool { kind != .player }
        var title: String {
            switch kind {
            case .player: String(localized: "Last Position")
            case .death: String(localized: "Last Death")
            case .respawn: String(localized: "Respawn Point")
            }
        }
    }

    /// The inspector and map consume the same valid saved locations.
    static func locations(of player: PlayerInfo) -> [Location] {
        let candidates: [(MapMarker.Kind, PlayerInfo.Location?)] = [
            (.player, player.position), (.death, player.lastDeath), (.respawn, player.respawn),
        ]
        return candidates.compactMap { kind, location in
            usable(location, of: player).map { Location(kind: kind, position: $0) }
        }
    }

    static func absentPlayerName(_ uuid: UUID, knownName: String?) -> String {
        knownName ?? String(localized: "a player not in this world (\(shortID(uuid))…)")
    }

    private static func shortID(_ uuid: UUID) -> String { String(uuid.uuidString.lowercased().prefix(8)) }

    /// Markers for one dimension: each mappable player's last position, last death and respawn point.
    static func markers(for players: [PlayerInfo], in dimensionID: String, singleplayerUUID: UUID?,
                        worldDataVersion: Int?, knownName: (UUID) -> String? = { _ in nil }) -> [MapMarker] {
        var markers: [MapMarker] = []
        for player in players where isMappable(player) {
            let name = label(of: player, singleplayerUUID: singleplayerUUID, knownName: knownName(player.uuid))
            let outdated = isOutdated(player, worldDataVersion: worldDataVersion)
            let id = player.uuid.uuidString
            // Keep the live-position badge last, matching the existing overlap priority.
            for saved in locations(of: player).reversed() where saved.position.dimension == dimensionID {
                let location = saved.position
                let label = switch saved.kind {
                case .player: name.text
                case .death: name.lastDeath
                case .respawn: name.respawn
                }
                markers.append(MapMarker(id: "\(id)-\(saved.kind)", playerID: player.uuid, kind: saved.kind,
                                         position: CGPoint(x: location.x, y: location.z), y: location.y,
                                         label: label, isOutdated: outdated))
            }
        }
        return markers
    }
}
