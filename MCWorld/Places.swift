import CoreGraphics
import Foundation
import MCWorldKit

/// Families of points of interest, shown and filtered together.
nonisolated enum PlaceGroup: String, CaseIterable, Codable, Sendable {
    case portal, bell, lodestone, bed, workstation, beeNest, lightningRod, other

    var name: String {
        switch self {
        case .portal: String(localized: "Nether Portals")
        case .bell: String(localized: "Village Bells")
        case .lodestone: String(localized: "Lodestones")
        case .bed: String(localized: "Beds")
        case .workstation: String(localized: "Villager Workstations")
        case .beeNest: String(localized: "Bee Nests and Hives")
        case .lightningRod: String(localized: "Lightning Rods")
        case .other: String(localized: "Other Places")
        }
    }

    var symbol: String {
        switch self {
        case .portal: "oval.portrait.fill"
        case .bell: "bell.fill"
        case .lodestone: "location.north.circle.fill"
        case .bed: "bed.double"
        case .workstation: "wrench.and.screwdriver.fill"
        case .beeNest: "hexagon.fill"
        case .lightningRod: "bolt.fill"
        case .other: "mappin"
        }
    }

    /// Marker color as sRGB hex.
    var color: UInt32 {
        switch self {
        case .portal: 0x6A1B9A
        case .bell: 0xC79A1E
        case .lodestone: 0x455A64
        case .bed: 0xB0413E
        case .workstation: 0x5D4037
        case .beeNest: 0xE0A800
        case .lightningRod: 0xD35400
        case .other: 0x566573
        }
    }

    /// Beds, workstations and bee nests number in the hundreds (558 beds in Ryan's Realm), so they
    /// start hidden.
    var isShownByDefault: Bool { [.portal, .bell, .lodestone].contains(self) }

    static let professions = ["armorer", "butcher", "cartographer", "cleric", "farmer", "fisherman", "fletcher",
                              "leatherworker", "librarian", "mason", "shepherd", "toolsmith", "weaponsmith"]

    static func group(for type: String) -> PlaceGroup {
        let name = type.hasPrefix("minecraft:") ? String(type.dropFirst(10)) : type
        switch name {
        case "nether_portal": return .portal
        case "meeting": return .bell
        case "lodestone": return .lodestone
        case "home": return .bed
        case "bee_nest", "beehive": return .beeNest
        case "lightning_rod": return .lightningRod
        case _ where professions.contains(name): return .workstation
        default: return .other
        }
    }
}

/// One place on the map. Nether portals are merged from their blocks into one place per portal.
nonisolated struct PlaceMarker: Identifiable, Equatable, Sendable {
    var id: String
    var type: String
    var group: PlaceGroup
    /// World X/Z of the marker (the center of a portal's blocks).
    var position: CGPoint
    var y: Int
    /// For beds and workstations: whether a villager has claimed it (no free tickets left).
    var isClaimed: Bool

    var name: String {
        let base = type.hasPrefix("minecraft:") ? String(type.dropFirst(10)) : type
        switch group {
        case .portal: return String(localized: "Nether Portal")
        case .bell: return String(localized: "Village Bell")
        case .lodestone: return String(localized: "Lodestone")
        case .bed: return isClaimed ? String(localized: "Villager’s Bed") : String(localized: "Bed")
        case .workstation:
            let job = base.prefix(1).uppercased() + base.dropFirst()
            return String(localized: "\(job)’s Workstation")
        case .beeNest: return base == "beehive" ? String(localized: "Beehive") : String(localized: "Bee Nest")
        case .lightningRod: return String(localized: "Lightning Rod")
        case .other: return base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    init(_ poi: PointOfInterest) {
        id = "\(poi.type)@\(poi.x),\(poi.y),\(poi.z)"
        type = poi.type
        group = PlaceGroup.group(for: poi.type)
        position = CGPoint(x: Double(poi.x) + 0.5, y: Double(poi.z) + 0.5)
        y = poi.y
        isClaimed = poi.freeTickets == 0 && (group == .bed || group == .workstation)
    }

    /// Merges touching portal blocks (sharing a face) into one place per portal, at their center.
    static func mergingPortals(_ places: [PlaceMarker], blocks: [PointOfInterest]) -> [PlaceMarker] {
        let portalBlocks = blocks.filter { PlaceGroup.group(for: $0.type) == .portal }
        guard !portalBlocks.isEmpty else { return places }
        struct Key: Hashable { var x: Int, y: Int, z: Int }
        var unvisited = Set(portalBlocks.map { Key(x: $0.x, y: $0.y, z: $0.z) })
        var portals: [PlaceMarker] = []
        while let seed = unvisited.first {
            unvisited.remove(seed)
            var stack = [seed], members: [Key] = []
            while let block = stack.popLast() {
                members.append(block)
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let next = Key(x: block.x + dx, y: block.y + dy, z: block.z + dz)
                    if unvisited.remove(next) != nil { stack.append(next) }
                }
            }
            let n = Double(members.count)
            let lowest = members.min { $0.y < $1.y }!
            var portal = PlaceMarker(PointOfInterest(type: "minecraft:nether_portal", x: lowest.x, y: lowest.y, z: lowest.z, freeTickets: 0))
            portal.position = CGPoint(x: members.map { Double($0.x) + 0.5 }.reduce(0, +) / n,
                                      y: members.map { Double($0.z) + 0.5 }.reduce(0, +) / n)
            portals.append(portal)
        }
        return places.filter { $0.group != .portal } + portals
    }
}

/// Reads every point of interest in a dimension, in parallel by region.
nonisolated enum PlaceScanner {
    @concurrent
    static func scan(_ dimension: MCWorldKit.Dimension) async -> [PlaceMarker] {
        let regions = dimension.pointOfInterestRegions()
        let blocks = await withTaskGroup(of: [PointOfInterest].self) { group in
            for region in regions {
                group.addTask { (try? dimension.pointsOfInterest(regionX: region.x, regionZ: region.z)) ?? [] }
            }
            var all: [PointOfInterest] = []
            for await found in group { all += found }
            return all
        }
        let places = blocks.map(PlaceMarker.init)
        return PlaceMarker.mergingPortals(places, blocks: blocks).sorted { $0.id < $1.id }
    }
}
