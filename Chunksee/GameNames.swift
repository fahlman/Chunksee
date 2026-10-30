import ChunkseeKit
import ChunkseeIndex
import Foundation
import SwiftUI

/// Immutable game-name service. Kit supplies the requested language and English fallback;
/// naming rules and their readable-ID fallbacks belong here, independent of views and reads.
nonisolated struct GameNames: Sendable {
    nonisolated struct Identity: Equatable, Sendable {
        let language: UUID?
        let enchantments: UUID?
    }

    /// Immutable definitions travel with their publication identity, including without a language.
    nonisolated final class Enchantments: Sendable {
        static let empty = Enchantments([:])
        let definitions: [String: EnchantmentDefinition]
        let identity: UUID?

        init(_ definitions: [String: EnchantmentDefinition]) {
            self.definitions = definitions
            identity = definitions.isEmpty ? nil : UUID()
        }

        func replacing(with definitions: [String: EnchantmentDefinition]) -> Enchantments {
            self.definitions == definitions ? self : Enchantments(definitions)
        }
    }

    private let languageID: UUID?
    private let language: GameLanguage?
    private var enchantments = Enchantments.empty

    var identity: Identity? {
        languageID == nil && enchantments.identity == nil ? nil
            : Identity(language: languageID, enchantments: enchantments.identity)
    }

    /// The deliberate state before a language is readable or after its source is retired.
    /// Callers must supply this state explicitly rather than silently defaulting to it.
    static let unavailable = GameNames(nil)

    init(_ language: GameLanguage?) {
        self.language = language
        languageID = language == nil ? nil : UUID()
    }

    func withEnchantments(_ enchantments: Enchantments) -> Self {
        var copy = self
        copy.enchantments = enchantments
        return copy
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
        // EffectsInInventory.getEffectName shows a suffix only for amplifiers one through nine.
        guard (1...9).contains(effect.amplifier) else { return base }
        return String(localized: "\(base) \(levelName(effect.level))", locale: locale)
    }

    private func levelName(_ level: Int) -> String {
        name(key: "enchantment.level.\(level)", fallback: LevelText.numeral(level))
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

    func dimensionStyle(for dimensionIDs: [String]) -> DimensionStyle {
        DimensionStyle(dimensionIDs: dimensionIDs)
    }

    /// Immutable dimension captions and collision context, without retaining a document.
    nonisolated struct DimensionStyle: FormatStyle, Sendable {
        private let dimensionIDs: [String]
        private var locale = Locale.autoupdatingCurrent

        fileprivate init(dimensionIDs: [String]) { self.dimensionIDs = dimensionIDs }

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ id: String) -> String {
            let name = name(id)
            let isAmbiguous = dimensionIDs.contains { $0 != id && self.name($0) == name }
            return isAmbiguous ? String(localized: "\(name) (\(id))", locale: locale) : name
        }

        func mapTitle(in dimensionID: String, world: String) -> String {
            let dimension = format(dimensionID)
            return String(localized: "Map of \(dimension) in \(world)", locale: locale)
        }

        private func name(_ id: String) -> String {
            switch id {
            case "minecraft:overworld": String(localized: "Overworld", locale: locale)
            case "minecraft:the_nether": String(localized: "The Nether", locale: locale)
            case "minecraft:the_end": String(localized: "The End", locale: locale)
            default: ReadableName.from(id)
            }
        }
    }
    /// Keep the saved custom name literal while retaining the translated kind beside it.
    func itemLabel(kind: String, customName: String?, locale: Locale = .current) -> String {
        let kind = item(kind)
        return customName.map { String(localized: "\(kind) “\($0)”", locale: locale) } ?? kind
    }

    func itemLabel(of item: ItemStack, locale: Locale = .current) -> String {
        let base = itemLabel(kind: item.id, customName: item.customName, locale: locale)
        guard item.customName == nil, let book = item.book, let title = book.title else { return base }
        let titled = itemLabel(kind: item.id, customName: title, locale: locale)
        return book.author.map { String(localized: "\(titled) by \($0)", locale: locale) } ?? titled
    }

    func itemName(of item: ItemStack, includingOne: Bool = false, locale: Locale = .current) -> String {
        ItemAppearance.counted(itemLabel(of: item, locale: locale), count: item.count,
                               includingOne: includingOne, locale: locale)
    }

    func itemDescription(of item: ItemStack, locale: Locale = .current) -> String {
        let text = itemName(of: item, locale: locale)
        return ItemAppearance.isEnchanted(item) ? String(localized: "\(text), enchanted", locale: locale) : text
    }

    func itemDetails(of item: ItemStack, locale: Locale = .current) -> String {
        var lines = [itemDescription(of: item, locale: locale)]
        lines += item.enchantments.sorted { $0.key < $1.key }.map {
            enchantmentName($0.key, level: $0.value, locale: locale)
        }
        if let wear = item.durability { lines.append(ItemAppearance.durability(wear, locale: locale)) }
        return lines.joined(separator: "\n")
    }

    private func enchantmentDescription(_ id: String) -> String {
        if let description = enchantments.definitions[id]?.description,
           let text = GameText.string(description, translation: { language?[$0] }) { return text }
        return ReadableName.from(id)
    }

    func enchantmentName(_ id: String, level: Int, locale: Locale = .current) -> String {
        let base = enchantmentDescription(id)
        // Minecraft's full name uses the actual description and hides I only when both levels
        // are one. A missing definition cannot establish that the enchantment has one level.
        if level == 1, enchantments.definitions[id]?.maximumLevel == 1 { return base }
        return String(localized: "\(base) \(levelName(level))", locale: locale)
    }

    func tradeDescription(_ item: ItemStack, locale: Locale = .current) -> String {
        let base = itemName(of: item, includingOne: true, locale: locale)
        let enchantments = item.enchantments.sorted { $0.key < $1.key }.map {
            enchantmentName($0.key, level: $0.value, locale: locale)
        }
        return enchantments.isEmpty ? base
            : String(localized: "\(base) (\(enchantments.joined(separator: ", ")))", locale: locale)
    }

    func tradeCost(of trade: Trade, locale: Locale = .current) -> String {
        let first = tradeDescription(trade.buy, locale: locale)
        guard let second = trade.buyB else { return first }
        return String(localized: "\(first) + \(tradeDescription(second, locale: locale))", locale: locale)
    }

    func tradeOffer(_ trade: Trade, locale: Locale = .current) -> String {
        let offer = String(localized: "\(tradeDescription(trade.sell, locale: locale)) for \(tradeCost(of: trade, locale: locale))",
                           locale: locale)
        return trade.isSoldOut ? String(localized: "\(offer) (sold out)", locale: locale) : offer
    }

    func tradeSearchText(of trade: Trade) -> String {
        let items = [trade.buy, trade.sell] + (trade.buyB.map { [$0] } ?? [])
        return items.flatMap {
            [itemLabel(of: $0), $0.id] + $0.enchantments.keys.sorted().flatMap { [$0, enchantmentDescription($0)] }
        }.joined(separator: " ")
    }

    func storedItems(_ totals: [StoredItemTotal]) -> [StoredItem] {
        totals.map {
            StoredItem(id: $0.id, name: itemLabel(kind: $0.id, customName: nil), count: $0.count, containers: $0.containers)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

extension EnvironmentValues {
    @Entry var gameNames = GameNames.unavailable
}
