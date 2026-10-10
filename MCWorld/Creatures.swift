import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI

/// Kinds of creatures the map can show. Farm animals and monsters number in the tens of thousands,
/// so only creatures someone cared about are shown: named ones, pets and villagers.
nonisolated enum CreatureGroup: String, CaseIterable, Codable, Sendable {
    case named, pet, villager

    var name: String {
        switch self {
        case .named: String(localized: "Named Creatures")
        case .pet: String(localized: "Pets")
        case .villager: String(localized: "Villagers and Traders")
        }
    }

    var symbol: String {
        switch self {
        case .named: "tag.fill"
        case .pet: "pawprint.fill"
        case .villager: "person.crop.square.fill"
        }
    }

    /// Marker color as sRGB hex.
    var color: UInt32 {
        switch self {
        case .named: 0x2E7D32
        case .pet: 0xAD1457
        case .villager: 0x795548
        }
    }

    var isShownByDefault: Bool { self != .villager }

    /// Villagers first (their trades are the reason to look), then pets, then other named creatures.
    static func group(for creature: Creature) -> CreatureGroup? {
        if creature.villager != nil { return .villager }
        if creature.owner != nil { return .pet }
        if creature.customName != nil { return .named }
        return nil
    }
}

/// A creature on the map.
nonisolated struct CreatureMarker: Identifiable, Equatable, Sendable {
    var id: String
    var creature: Creature
    var group: CreatureGroup
    var dimension: String

    var position: CGPoint { CGPoint(x: creature.x, y: creature.z) }

    /// "Summer", or the kind for unnamed ones: "Wolf", "Farmer" for a villager with a job.
    var name: String {
        if let name = creature.customName { return name }
        if let job = creature.villager?.profession, job != "minecraft:none" { return ReadableName.from(job) }
        return ReadableName.from(creature.id)
    }

    init?(_ creature: Creature, dimension: String) {
        guard let group = CreatureGroup.group(for: creature) else { return nil }
        self.creature = creature
        self.group = group
        self.dimension = dimension
        id = "\(creature.id)@\(creature.x),\(creature.y),\(creature.z)"
    }
}

/// Reads every shown creature in a dimension, in parallel by region.
nonisolated enum CreatureScanner {
    @concurrent
    static func scan(_ reader: RegionReader) async -> [CreatureMarker] {
        let dimension = reader.dimension.id
        return await reader.everyRegion { await $0.creatures($1) }.flatMap(\.value)
            .compactMap { CreatureMarker($0, dimension: dimension) }.sorted { $0.id < $1.id }
    }
}

/// Details of the selected creature: kind, owner, and a villager's job and trades.
struct CreatureCard: View {
    let session: WorldSession
    let marker: CreatureMarker

    var body: some View {
        MapCard(title: Text(marker.name), symbol: marker.group.symbol, width: 320, close: { session.selection = nil }) {
            Text("\(ReadableName.from(marker.creature.id)) at X \(Int(marker.creature.x.rounded(.down))), Y \(Int(marker.creature.y.rounded(.down))), Z \(Int(marker.creature.z.rounded(.down)))")
                .foregroundStyle(.secondary)
            if let owner = marker.creature.owner {
                Label("Tamed by \(session.name(ofPlayerWith: owner))", systemImage: "person.fill")
            }
            if let villager = marker.creature.villager {
                if let job = villager.profession, job != "minecraft:none" {
                    Text("\(ReadableName.from(job)), \(Self.levelName(villager.level))")
                } else if marker.creature.id == "minecraft:villager" {
                    Text("No job yet")
                }
                if !villager.trades.isEmpty {
                    Divider()
                    ForEach(Array(villager.trades.enumerated()), id: \.offset) { _, trade in
                        HStack {
                            Text(Self.describe(trade.buy) + (trade.buyB.map { " + " + Self.describe($0) } ?? ""))
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(Self.describe(trade.sell))
                        }
                        .font(.callout)
                        .strikethrough(trade.isSoldOut)
                        .foregroundStyle(trade.isSoldOut ? .secondary : .primary)
                        .help(trade.isSoldOut ? "Sold out until the villager restocks" : "")
                    }
                }
            }
        }
    }

    static func describe(_ item: ItemStack) -> String {
        "\(item.count) \(ReadableName.from(item.id))"
    }

    /// The game's names for villager levels 1–5.
    static func levelName(_ level: Int?) -> String {
        switch level {
        case 2: String(localized: "Apprentice")
        case 3: String(localized: "Journeyman")
        case 4: String(localized: "Expert")
        case 5: String(localized: "Master")
        default: String(localized: "Novice")
        }
    }
}
