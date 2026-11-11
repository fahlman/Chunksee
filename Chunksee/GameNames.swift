import ChunkseeKit
import Foundation
import SwiftUI

/// Immutable game-name service. Kit supplies the requested language and English fallback;
/// naming rules and their readable-ID fallbacks belong here, independent of views and reads.
nonisolated struct GameNames: Sendable {
    let identity: UUID?
    private let language: GameLanguage?

    /// The deliberate state before a language is readable or after its source is retired.
    /// Callers must supply this state explicitly rather than silently defaulting to it.
    static let unavailable = GameNames(nil)

    init(_ language: GameLanguage?) {
        self.language = language
        identity = language == nil ? nil : UUID()
    }

    func name(key: String, fallback: String) -> String { language?[key] ?? fallback }

    func hasSameContents(as language: GameLanguage?) -> Bool { self.language == language }

    func name(_ id: String, in registry: String) -> String {
        translation(id, in: registry) ?? ReadableName.from(id)
    }

    func translation(_ id: String, in registry: String) -> String? {
        guard let id = Identifier(id) else { return nil }
        return language?["\(registry).\(id.namespace).\(id.path.replacingOccurrences(of: "/", with: "."))"]
    }

    func item(_ id: String) -> String {
        translation(id, in: "item") ?? translation(id, in: "block") ?? ReadableName.from(id)
    }

    func advancement(_ id: String, title: TextComponent.Content?) -> String {
        if let title, let text = GameText.string(title, translation: { language?[$0] }) { return text }
        return ReadableName.from(id)
    }

    func effect(_ effect: StatusEffect, locale: Locale = .current) -> String {
        let base = name(effect.id, in: "effect")
        guard effect.level > 1 else { return base }
        return String(localized: "\(base) \(LevelText.numeral(effect.level))", locale: locale)
    }

    func merchantLevel(_ level: Int?) -> String? {
        guard let level else { return nil }
        return name(key: "merchant.level.\(level)", fallback: String(localized: "Level \(level)"))
    }

    func statisticCategory(_ id: String) -> String {
        id == "minecraft:custom" ? String(localized: "General") : ReadableName.from(id)
    }

    func statistic(_ row: StatisticRow) -> String {
        switch row.categoryID {
        case "minecraft:custom": name(row.statisticID, in: "stat")
        case "minecraft:mined": name(row.statisticID, in: "block")
        case "minecraft:killed", "minecraft:killed_by": name(row.statisticID, in: "entity")
        case "minecraft:used", "minecraft:broken", "minecraft:crafted", "minecraft:picked_up", "minecraft:dropped":
            item(row.statisticID)
        default: ReadableName.from(row.statisticID)
        }
    }

    func difficulty(_ id: String?, isHardcore: Bool, isLocked: Bool) -> String {
        var text = id.map { name(key: "options.difficulty.\($0)", fallback: ReadableName.from($0)) } ?? String(localized: "Unknown")
        if isHardcore {
            let hardcore = name(key: "options.difficulty.hardcore", fallback: ReadableName.from("hardcore"))
            text = String(localized: "\(text), \(hardcore)")
        }
        if isLocked { text = String(localized: "\(text), locked") }
        return text
    }

    func gameMode(_ mode: GameMode?) -> String {
        guard let mode else { return String(localized: "Unknown") }
        let id: String
        switch mode {
        case .survival: id = "survival"
        case .creative: id = "creative"
        case .adventure: id = "adventure"
        case .spectator: id = "spectator"
        }
        return name(key: "gameMode.\(id)", fallback: ReadableName.from(id))
    }
}

extension EnvironmentValues {
    @Entry var gameNames = GameNames.unavailable
}
