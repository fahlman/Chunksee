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
        case .mob: String(localized: "Mobs")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .named: "tag.fill"
        case .pet: "pawprint.fill"
        case .villager: "person.crop.square.fill"
        case .mob: "hare.fill"
        }
    }

    /// Marker color as sRGB hex.
    nonisolated var color: UInt32 {
        switch self {
        case .named: 0x2E7D32
        case .pet: 0xAD1457
        case .villager: 0x795548
        case .mob: 0x546E7A
        }
    }

    nonisolated var isShownByDefault: Bool { self == .named || self == .pet }
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
                InspectorHeading(title: Text(marker.name), symbol: marker.group.symbol,
                                 picture: .mob(marker.creature.id))
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
    @Environment(\.gameNames) private var gameNames
    @Environment(\.locale) private var locale
    @ViewBuilder var header: Header
    @ViewBuilder var location: Location

    var body: some View {
        Section {
            LabeledContent("Kind", value: ReadableName.from(creature.id))
            location
            if let owner = creature.owner {
                LabeledContent("Tamed By", value: session.presentation.name(ofPlayerWith: owner))
            }
            PetDetailRows(creature: creature)
            if let profession = VillagerText.inspectorProfession(creature, definitions: session.details.definitions.trading, gameNames: gameNames) {
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
        if let equipment = creature.equipment {
            EquipmentSection(items: equipment)
        }
        if let trades = creature.villager?.trades, !trades.isEmpty {
            Section("Trades") {
                ForEach(Array(trades.enumerated()), id: \.offset) { _, trade in
                    ItemLabel(item: trade.sell, title: Text(gameNames.tradeOffer(trade, locale: locale)))
                        .strikethrough(trade.isSoldOut)
                        .foregroundStyle(trade.isSoldOut ? .secondary : .primary)
                        .help(trade.isSoldOut ? "Sold out until the villager restocks" : "")
                }
            }
        }
    }
}
