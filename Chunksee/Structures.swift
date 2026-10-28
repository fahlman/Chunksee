import CoreGraphics
import Foundation
import ChunkseeKit

/// How a family of structures is shown and filtered. Several structure IDs can share one group,
/// such as the village variants supplied by the game.
nonisolated enum StructureGroup: String, CaseIterable, Codable, Sendable {
    case village, stronghold, ancientCity, trialChambers, monument, mansion, temple, ruins, ruinedPortal
    case shipwreck, buriedTreasure, outpost, mineshaft, fortress, bastion, netherFossil, endCity, abandonedCamp, other

    var name: String {
        switch self {
        case .village: String(localized: "Villages")
        case .stronghold: String(localized: "Strongholds")
        case .ancientCity: String(localized: "Ancient Cities")
        case .trialChambers: String(localized: "Trial Chambers")
        case .monument: String(localized: "Ocean Monuments")
        case .mansion: String(localized: "Woodland Mansions")
        case .temple: String(localized: "Temples and Huts")
        case .ruins: String(localized: "Ruins")
        case .ruinedPortal: String(localized: "Ruined Portals")
        case .shipwreck: String(localized: "Shipwrecks")
        case .buriedTreasure: String(localized: "Buried Treasure")
        case .outpost: String(localized: "Pillager Outposts")
        case .mineshaft: String(localized: "Mineshafts")
        case .fortress: String(localized: "Nether Fortresses")
        case .bastion: String(localized: "Bastion Remnants")
        case .netherFossil: String(localized: "Nether Fossils")
        case .endCity: String(localized: "End Cities")
        case .abandonedCamp: String(localized: "Abandoned Camps")
        case .other: String(localized: "Other Structures")
        }
    }

    var symbol: String {
        switch self {
        case .village: "house.fill"
        case .stronghold: "door.left.hand.closed"
        case .ancientCity: "building.2.fill"
        case .trialChambers: "square.stack.3d.up.fill"
        case .monument: "water.waves"
        case .mansion: "house.lodge.fill"
        case .temple: "triangle.fill"
        case .ruins: "building.columns.fill"
        case .ruinedPortal: "circle.dashed"
        case .shipwreck: "ferry.fill"
        case .buriedTreasure: "shippingbox.fill"
        case .outpost: "flag.fill"
        case .mineshaft: "hammer.fill"
        case .fortress: "shield.fill"
        case .bastion: "crown.fill"
        case .netherFossil: "fossil.shell.fill"
        case .endCity: "building.2.crop.circle"
        case .abandonedCamp: "tent.fill"
        case .other: "square.dashed"
        }
    }

    /// Marker color as sRGB hex.
    var color: UInt32 {
        switch self {
        case .village: 0x2E9E4F
        case .stronghold: 0x7A4FD1
        case .ancientCity: 0x0E5C66
        case .trialChambers: 0xC0661B
        case .monument: 0x1E88A8
        case .mansion: 0x6B4426
        case .temple: 0xC9A227
        case .ruins: 0x6E7681
        case .ruinedPortal: 0x8E44AD
        case .shipwreck: 0x8D6E4A
        case .buriedTreasure: 0xD4A017
        case .outpost: 0xA93226
        case .mineshaft: 0x5D6D7E
        case .fortress: 0x922B21
        case .bastion: 0x2C2C2C
        case .netherFossil: 0xBFB8A5
        case .endCity: 0xB455B6
        case .abandonedCamp: 0x566573
        case .other: 0x566573
        }
    }

    /// Hidden until turned on: there are far more of these than anything else (1,711 mineshafts and
    /// 323 Nether fossils in Ryan's Realm), and they'd bury the rest.
    var isShownByDefault: Bool { self != .mineshaft && self != .netherFossil }

    /// These associations choose presentation families; the game supplies their members.
    private var tagID: String? {
        switch self {
        case .village: "minecraft:village"
        case .ruins: "minecraft:ocean_ruin"
        case .ruinedPortal: "minecraft:ruined_portal"
        case .shipwreck: "minecraft:shipwreck"
        case .mineshaft: "minecraft:mineshaft"
        case .abandonedCamp: "minecraft:abandoned_camp"
        default: nil
        }
    }

    static var tagIDs: Set<String> { Set(allCases.compactMap(\.tagID)) }

    /// One immutable grouping snapshot, shared by every region projection for this world.
    struct Catalog: Sendable, Equatable {
        private var byID: [String: StructureGroup] = [:]
        private var availableTags: Set<String>

        init(tags: [String: GameTag]) {
            availableTags = Set(tags.keys)
            // A saved structure gets one row/marker. Overlapping tags use the existing group
            // order, independent of resource dictionary iteration, before design-only groups.
            for group in StructureGroup.allCases {
                guard let tag = group.tagID.flatMap({ tags[$0] }) else { continue }
                for member in tag.members where byID[member.id] == nil { byID[member.id] = group }
            }
        }

        func group(for id: String) -> StructureGroup {
            guard let id = Identifier(id)?.description else { return .other }
            if let group = byID[id] { return group }
            let design = StructureGroup.designGroup(for: id)
            if design != .other { return design }
            // Keep the previous presentation when this family's game data is unavailable.
            // A readable tag, even an empty one, overrides these no-game-files fallbacks.
            guard let fallback = StructureGroup.unavailableTagGroup(for: id),
                  let tag = fallback.tagID, !availableTags.contains(tag) else { return .other }
            return fallback
        }
    }

    private static func unavailableTagGroup(for id: String) -> StructureGroup? {
        guard let name = ReadableName.vanillaPath(id) else { return nil }
        switch name {
        case _ where name.hasPrefix("village"): return .village
        case _ where name.hasPrefix("ocean_ruin"): return .ruins
        case _ where name.hasPrefix("ruined_portal"): return .ruinedPortal
        case _ where name.hasPrefix("shipwreck"): return .shipwreck
        case _ where name.hasPrefix("mineshaft"): return .mineshaft
        default: return nil
        }
    }

    /// Families without a game tag remain the app's presentation choices.
    private static func designGroup(for id: String) -> StructureGroup {
        guard let name = ReadableName.vanillaPath(id) else { return .other }
        switch name {
        case "stronghold": return .stronghold
        case "ancient_city": return .ancientCity
        case "trial_chambers": return .trialChambers
        case "monument": return .monument
        case "mansion": return .mansion
        case "desert_pyramid", "jungle_pyramid", "swamp_hut", "igloo": return .temple
        case "trail_ruins": return .ruins
        case "buried_treasure": return .buriedTreasure
        case "pillager_outpost": return .outpost
        case "fortress": return .fortress
        case "bastion_remnant": return .bastion
        case "nether_fossil": return .netherFossil
        case "end_city": return .endCity
        default: return .other
        }
    }
}

/// One structure on the map.
nonisolated struct StructureMarker: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var structureID: String
    var group: StructureGroup
    /// World X/Z rectangle around all of the structure's pieces.
    var bounds: CGRect
    /// The vertical center of the recorded pieces; absent when the start has no bounds.
    var y: Int?
    /// For a stronghold, the center of its End portal room (piece `minecraft:shpr`; every stronghold in
    /// Ryan's Realm has exactly one).
    var portalRoom: CGPoint?

    var position: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// The game has no structure-name language keys; keep the saved ID's word order.
    var name: String { ReadableName.from(structureID) }

    init(_ start: StructureStart, groups: StructureGroup.Catalog = .init(tags: [:])) {
        id = "\(start.id)@\(start.chunkX),\(start.chunkZ)"
        structureID = start.id
        group = groups.group(for: start.id)
        if let box = start.bounds {
            bounds = CGRect(x: box.minX, y: box.minZ, width: box.maxX - box.minX + 1, height: box.maxZ - box.minZ + 1)
            y = box.minY + (box.maxY - box.minY + 1) / 2
        } else {
            // No pieces recorded: the start chunk itself.
            bounds = CGRect(x: start.chunkX * 16, y: start.chunkZ * 16, width: 16, height: 16)
        }
        portalRoom = start.pieces.first { $0.id == "minecraft:shpr" }.map {
            CGPoint(x: Double($0.box.minX + $0.box.maxX + 1) / 2, y: Double($0.box.minZ + $0.box.maxZ + 1) / 2)
        }
    }
}
