import Foundation

extension GameNames {
    /// Keep the personal pronoun, literal account name and unnamed UUID distinct. A stored
    /// fallback string would lose that distinction before the current naming service sees it.
    nonisolated enum PlayerName: Equatable, Sendable {
        case you
        case named(String)
        case unnamed(UUID)

        init(playerID: UUID, singleplayerUUID: UUID?, knownName: String?) {
            if let knownName { self = .named(knownName) }
            else if playerID == singleplayerUUID { self = .you }
            else { self = .unnamed(playerID) }
        }
    }

    nonisolated func player(_ name: PlayerName, locale: Locale = .current) -> String {
        switch name {
        case .you: String(localized: "You", locale: locale)
        case .named(let name): name
        case .unnamed(let uuid):
            String(localized: "Player \(String(uuid.uuidString.lowercased().prefix(8)))", locale: locale)
        }
    }

    nonisolated func playerMarker(_ marker: MapMarker, locale: Locale = .current) -> String {
        switch marker.kind {
        case .player: player(marker.name, locale: locale)
        case .death:
            switch marker.name {
            case .you: String(localized: "Where you last died", locale: locale)
            case .named, .unnamed: String(localized: "Where \(player(marker.name, locale: locale)) last died", locale: locale)
            }
        case .respawn:
            switch marker.name {
            case .you: String(localized: "Your respawn point", locale: locale)
            case .named, .unnamed: String(localized: "\(player(marker.name, locale: locale))’s respawn point", locale: locale)
            }
        }
    }

    nonisolated func playerInventory(_ name: PlayerName, locale: Locale = .current) -> String {
        switch name {
        case .you: String(localized: "Your inventory", locale: locale)
        case .named, .unnamed: String(localized: "\(player(name, locale: locale))’s inventory", locale: locale)
        }
    }

    nonisolated func playerEnderChest(_ name: PlayerName, locale: Locale = .current) -> String {
        switch name {
        case .you: String(localized: "Your ender chest", locale: locale)
        case .named, .unnamed: String(localized: "\(player(name, locale: locale))’s ender chest", locale: locale)
        }
    }

    nonisolated func playerLocation(_ kind: MapMarker.Kind, locale: Locale = .current) -> String {
        switch kind {
        case .player: String(localized: "Last Location", locale: locale)
        case .death: String(localized: "Last Death", locale: locale)
        case .respawn: String(localized: "Respawn Point", locale: locale)
        }
    }

    nonisolated func absentPlayer(_ uuid: UUID, knownName: String?, locale: Locale = .current) -> String {
        knownName ?? String(localized: "\(player(.unnamed(uuid), locale: locale)) (not in this world)", locale: locale)
    }
}
