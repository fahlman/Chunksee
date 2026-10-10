import CoreGraphics
import Foundation
import MCWorldKit

/// How a family of structures is shown and filtered. Several structure ids share one group, such as
/// the five kinds of village.
nonisolated enum StructureGroup: String, CaseIterable, Codable, Sendable {
    case village, stronghold, ancientCity, trialChambers, monument, mansion, temple, ruins, ruinedPortal
    case shipwreck, buriedTreasure, outpost, mineshaft, fortress, bastion, netherFossil, endCity, other

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
        case .other: String(localized: "Other Structures")
        }
    }

    var symbol: String {
        switch self {
        case .village: "house.fill"
        case .stronghold: "eye.fill"
        case .ancientCity: "building.2.fill"
        case .trialChambers: "square.grid.3x3.fill"
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
        case .other: "mappin"
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
        case .other: 0x566573
        }
    }

    /// Hidden until turned on: there are far more of these than anything else (1,711 mineshafts and
    /// 323 Nether fossils in Ryan's Realm), and they'd bury the rest.
    var isShownByDefault: Bool { self != .mineshaft && self != .netherFossil }

    static func group(for id: String) -> StructureGroup {
        let name = id.hasPrefix("minecraft:") ? String(id.dropFirst(10)) : id
        switch name {
        case _ where name.hasPrefix("village"): return .village
        case "stronghold": return .stronghold
        case "ancient_city": return .ancientCity
        case "trial_chambers": return .trialChambers
        case "monument": return .monument
        case "mansion": return .mansion
        case "desert_pyramid", "jungle_pyramid", "swamp_hut", "igloo": return .temple
        case _ where name.hasPrefix("ocean_ruin"), "trail_ruins": return .ruins
        case _ where name.hasPrefix("ruined_portal"): return .ruinedPortal
        case _ where name.hasPrefix("shipwreck"): return .shipwreck
        case "buried_treasure": return .buriedTreasure
        case "pillager_outpost": return .outpost
        case _ where name.hasPrefix("mineshaft"): return .mineshaft
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
    /// For a stronghold, the center of its End portal room (piece `minecraft:shpr`; every stronghold in
    /// Ryan's Realm has exactly one).
    var portalRoom: CGPoint?

    var position: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// "Plains Village", "Stronghold", "Ocean Ruin Cold" and so on, from the id. Minecraft's own
    /// names live in its language files, which can't be redistributed.
    var name: String {
        let base = structureID.split(separator: ":").last.map(String.init) ?? structureID
        var words = base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        // Variants come last in ids ("village_plains", "ocean_ruin_cold"); English puts them first.
        let variants: Set<String> = ["Plains", "Desert", "Savanna", "Snowy", "Taiga", "Cold", "Warm", "Ocean",
                                     "Jungle", "Mountain", "Swamp", "Nether", "Beached", "Mesa"]
        if words.count >= 2, let last = words.last, variants.contains(last) {
            words.removeLast()
            words.insert(last, at: 0)
        }
        return words.joined(separator: " ")
    }

    init(_ start: StructureStart) {
        id = "\(start.id)@\(start.chunkX),\(start.chunkZ)"
        structureID = start.id
        group = StructureGroup.group(for: start.id)
        if let box = start.bounds {
            bounds = CGRect(x: box.minX, y: box.minZ, width: box.maxX - box.minX + 1, height: box.maxZ - box.minZ + 1)
        } else {
            // No pieces recorded: the start chunk itself.
            bounds = CGRect(x: start.chunkX * 16, y: start.chunkZ * 16, width: 16, height: 16)
        }
        portalRoom = start.pieces.first { $0.id == "minecraft:shpr" }.map {
            CGPoint(x: Double($0.box.minX + $0.box.maxX + 1) / 2, y: Double($0.box.minZ + $0.box.maxZ + 1) / 2)
        }
    }
}

/// Reads every structure in a dimension. Only structure entries are decoded (block data is
/// skipped), and regions are read in parallel.
nonisolated enum StructureScanner {
    @concurrent
    static func scan(_ reader: RegionReader) async -> [StructureMarker] {
        await reader.everyRegion { await $0.structures($1) }.flatMap(\.value).sorted { $0.id < $1.id }
    }
}
