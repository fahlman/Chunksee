import CoreGraphics
import Foundation
import ChunkseeKit
import ChunkseeIndex
import SwiftUI

/// Shared category identity with native names, symbols, colors and visibility defaults.
typealias CreatureGroup = CreatureEntry.Group

extension CreatureGroup {
    nonisolated var name: String {
        switch self {
        case .named: String(localized: "Named Creatures")
        case .pet: String(localized: "Pets")
        case .villager: String(localized: "Villagers and Traders")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .named: "tag.fill"
        case .pet: "pawprint.fill"
        case .villager: "person.crop.square.fill"
        }
    }

    /// Marker color as sRGB hex.
    nonisolated var color: UInt32 {
        switch self {
        case .named: 0x2E7D32
        case .pet: 0xAD1457
        case .villager: 0x795548
        }
    }

    nonisolated var isShownByDefault: Bool { self != .villager }
}

/// A creature on the map.
nonisolated struct CreatureMarker: Identifiable, Equatable, Sendable {
    private let entry: CreatureEntry
    /// Defaults to the shared identity; carried pets may supply their carrier/shoulder fallback.
    private var projectedID: String?
    var id: String {
        get { projectedID ?? entry.id }
        set { projectedID = newValue }
    }
    var creature: Creature { entry.creature }
    var group: CreatureGroup { entry.group }
    var dimension: String
    /// Present only for a player-carried pet; this is independent of its saved owner.
    var carrier: UUID?

    var position: CGPoint { CGPoint(x: creature.x, y: creature.z) }

    var name: String { creature.displayName }

    init?(_ creature: Creature, dimension: String) {
        guard let entry = CreatureEntry(creature) else { return nil }
        self.init(entry, dimension: dimension)
    }

    init(_ entry: CreatureEntry, dimension: String) {
        self.entry = entry
        self.dimension = dimension
    }
}

extension Creature {
    /// "Summer", or the kind for unnamed ones: "Wolf", "Farmer" for a villager with a profession.
    nonisolated var displayName: String {
        if let customName { return customName }
        if let villager, let profession = VillagerText.professionName(villager) { return profession }
        return ReadableName.from(id)
    }
}

/// Details of the selected creature in the inspector.
struct CreatureDetailView: View {
    let session: WorldSession
    let marker: CreatureMarker

    var body: some View {
        Form {
            CreatureDetailSections(session: session, creature: marker.creature) {
                InspectorHeading(title: Text(marker.name), symbol: marker.group.symbol)
            } location: {
                LocationRow(session: session,
                            destination: MapDestination(coordinates: Coordinates(marker.position, y: marker.creature.y),
                                                        dimension: marker.dimension))
                if let carrier = marker.carrier {
                    LabeledContent("Riding With", value: session.presentation.name(ofPlayerWith: carrier))
                }
            }
            SelectedSearchSection(session: session)
        }
        .formStyle(.grouped)
    }
}

/// The same applicable details appear for a located creature and a player-carried creature.
/// Callers supply their heading and location without duplicating pet, equipment or trade rules.
struct CreatureDetailSections<Header: View, Location: View>: View {
    let session: WorldSession
    let creature: Creature
    @ViewBuilder var header: Header
    @ViewBuilder var location: Location

    var body: some View {
        Section {
            LabeledContent("Kind", value: ReadableName.from(creature.id))
            location
            if let owner = creature.owner {
                LabeledContent("Tamed By", value: session.presentation.name(ofPlayerWith: owner))
                PetDetailRows(creature: creature)
            }
            if let profession = VillagerText.inspectorProfession(creature) {
                LabeledContent("Profession", value: profession)
            }
        } header: {
            header
        }
        if HealthPresentation(health: creature.health, maximum: creature.maxHealth).isAvailable {
            Section("Status") {
                HealthRow(health: creature.health, maximum: creature.maxHealth)
            }
        }
        if creature.owner != nil, let equipment = creature.equipment {
            EquipmentSection(items: equipment)
        }
        if let trades = creature.villager?.trades, !trades.isEmpty {
            Section("Trades") {
                ForEach(Array(trades.enumerated()), id: \.offset) { _, trade in
                    ItemLabel(id: trade.sell.id, title: Text(TradeText.offer(trade)),
                              isEnchanted: ItemAppearance.isEnchanted(trade.sell))
                        .strikethrough(trade.isSoldOut)
                        .foregroundStyle(trade.isSoldOut ? .secondary : .primary)
                        .help(trade.isSoldOut ? "Sold out until the villager restocks" : "")
                }
            }
        }
    }
}

/// How villagers and their trades read, in the creature details and in trade search.
nonisolated enum TradeText {
    static func offer(_ trade: Trade) -> String {
        let offer = String(localized: "\(describe(trade.sell)) for \(cost(of: trade))")
        return trade.isSoldOut ? String(localized: "\(offer) (sold out)") : offer
    }

    /// "24 Emerald", "1 Enchanted Book (Mending)", "1 Diamond Sword (Sharpness V)".
    static func describe(_ item: ItemStack) -> String {
        let base = ItemAppearance.name(of: item, includingOne: true)
        let enchantments = item.enchantments.sorted { $0.key < $1.key }.map { enchantmentName($0.key, level: $0.value) }
        return enchantments.isEmpty ? base : String(localized: "\(base) (\(enchantments.joined(separator: ", ")))")
    }

    /// What the villager asks for: "24 Emerald + 1 Book".
    static func cost(of trade: Trade) -> String {
        let first = describe(trade.buy)
        guard let second = trade.buyB else { return first }
        return String(localized: "\(first) + \(describe(second))")
    }

    /// The text trade search matches: every item's name and id, and the enchantments' names.
    static func searchText(of trade: Trade) -> String {
        let items = [trade.buy, trade.sell] + (trade.buyB.map { [$0] } ?? [])
        return items.flatMap { [ItemAppearance.label(of: $0), $0.id] + $0.enchantments.keys.map { ReadableName.from($0) } }
            .joined(separator: " ")
    }

    static func enchantmentName(_ id: String, level: Int) -> String {
        EnchantmentStyle(level: level).format(id)
    }

    nonisolated struct EnchantmentStyle: FormatStyle, Sendable {
        private let level: Int
        private var locale = Locale.autoupdatingCurrent

        init(level: Int) { self.level = level }

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ id: String) -> String {
            let name = ReadableName.from(id)
            if level == 1, Self.singleLevelEnchantments.contains(id) { return name }
            return String(localized: "\(name) \(LevelText.numeral(level))", locale: locale)
        }

        // Vanilla 26.3 data/minecraft/enchantment/*.json. The game hides the suffix only when
        // both the saved and maximum levels are 1; unknown/modded enchantments keep their level.
        private static let singleLevelEnchantments: Set<String> = [
            "minecraft:aqua_affinity", "minecraft:binding_curse", "minecraft:channeling",
            "minecraft:flame", "minecraft:infinity", "minecraft:mending", "minecraft:multishot",
            "minecraft:silk_touch", "minecraft:vanishing_curse",
        ]
    }
}
