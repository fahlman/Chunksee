import CoreGraphics
import Foundation
import MCWorldKit
import SwiftUI

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
    /// For Nether portals: the whole portal (its blocks), as grouped by MCWorldKit.
    var portal: NetherPortal?

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
        case .other: return ReadableName.from(base)
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

    /// One place for a whole Nether portal, at the center of its blocks.
    init(_ portal: NetherPortal) {
        self.init(PointOfInterest(type: "minecraft:nether_portal", x: portal.entry.x, y: portal.minY, z: portal.entry.z, freeTickets: 0))
        id = "portal@\(portal.entry.x),\(portal.entry.y),\(portal.entry.z)"
        position = CGPoint(x: portal.centerX, y: portal.centerZ)
        self.portal = portal
    }
}

/// Reads every point of interest in a dimension, in parallel by region.
nonisolated enum PlaceScanner {
    @concurrent
    static func scan(_ dimension: MCWorldKit.Dimension, cache: ScanCache = .off) async -> [PlaceMarker] {
        let regions = dimension.pointOfInterestRegions()
        let blocks = await withTaskGroup(of: [PointOfInterest].self) { group in
            for region in regions {
                group.addTask {
                    let file = dimension.poiDirectory.appendingPathComponent("r.\(region.x).\(region.z).mca")
                    return cache.value("places", region: RegionCoordinate(x: region.x, z: region.z), sources: [file]) {
                        (try? dimension.pointsOfInterest(regionX: region.x, regionZ: region.z)) ?? []
                    }
                }
            }
            var all: [PointOfInterest] = []
            for await found in group { all += found }
            return all
        }
        // Portal blocks become one place per portal (MCWorldKit owns the grouping rule).
        let others = blocks.filter { PlaceGroup.group(for: $0.type) != .portal }.map(PlaceMarker.init)
        let portals = NetherPortal.portals(from: blocks, in: dimension.id).map(PlaceMarker.init)
        return (others + portals).sorted { $0.id < $1.id }
    }
}

/// Where a portal leads, as the app shows it.
nonisolated enum PortalLinkStatus: Equatable, Sendable {
    /// Leads to a portal that leads back here.
    case linked
    /// Leads to a portal that leads back to a different one.
    case oneWay
    /// No portal in range on the other side; the game would build a new one.
    case noPartner

    /// A portal's status given every portal by dimension, or `nil` while the other side is unknown.
    static func status(of portal: NetherPortal, portals: [String: [NetherPortal]]) -> PortalLinkStatus? {
        func link(_ p: NetherPortal) -> NetherPortal.Link? {
            guard let target = NetherPortal.targetDimension(from: p.dimension), let candidates = portals[target] else { return nil }
            return p.link(into: candidates)
        }
        switch link(portal) {
        case .portal(let target, _)?:
            guard case .portal(let back, _)? = link(target) else { return nil }
            return back == portal ? .linked : .oneWay
        case .wouldCreateNewPortal?:
            return .noPartner
        case nil:
            return nil
        }
    }
}

/// Where the selected Nether portal leads, and whether the link goes both ways.
struct PortalCard: View {
    let session: WorldSession
    let portal: NetherPortal

    var body: some View {
        MapCard(title: Text("Nether Portal"), symbol: "oval.portrait.fill", close: { session.selection = nil }) {
            Text("X \(Int(portal.centerX.rounded(.down)))  Y \(portal.minY)  Z \(Int(portal.centerZ.rounded(.down)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider()
            switch session.link(for: portal) {
            case .portal(let target, _)?:
                Text("Leads to the portal in \(session.dimensionName(target.dimension)) at X \(Int(target.centerX.rounded(.down))), Z \(Int(target.centerZ.rounded(.down))).")
                if session.linkStatus(for: portal) == .oneWay, case .portal(let back, _)? = session.link(for: target) {
                    Label("One-way: that portal leads back to a different one, at X \(Int(back.centerX.rounded(.down))), Z \(Int(back.centerZ.rounded(.down))).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Show the Other Side") { session.show(target) }
            case .wouldCreateNewPortal(let destination)?:
                Label("No portal in \(session.dimensionName(NetherPortal.targetDimension(from: portal.dimension) ?? "")) is close enough. Going through would make the game build a new one near X \(destination.x), Z \(destination.z).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case nil:
                ProgressView().controlSize(.small)
            }
            Text("Predicted with Minecraft’s linking rule from the portal’s bottom center.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
