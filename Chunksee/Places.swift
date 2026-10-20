import CoreGraphics
import Foundation
import ChunkseeKit
import SwiftUI

/// Families of points of interest, shown and filtered together.
nonisolated enum PlaceGroup: String, CaseIterable, Codable, Sendable {
    case portal, bell, lodestone, bed, workstation, beeNest, lightningRod, spawner, unopenedLoot, other

    var name: String {
        switch self {
        case .portal: String(localized: "Nether Portals")
        case .bell: String(localized: "Village Bells")
        case .lodestone: String(localized: "Lodestones")
        case .bed: String(localized: "Beds")
        case .workstation: String(localized: "Villager Workstations")
        case .beeNest: String(localized: "Bee Nests and Hives")
        case .lightningRod: String(localized: "Lightning Rods")
        case .spawner: String(localized: "Monster Spawners")
        case .unopenedLoot: String(localized: "Unopened Loot")
        case .other: String(localized: "Other Places")
        }
    }

    var symbol: String {
        switch self {
        case .portal: "oval.portrait.fill"
        case .bell: "bell.fill"
        case .lodestone: "location.north.circle.fill"
        case .bed: "bed.double.fill"
        case .workstation: "wrench.and.screwdriver.fill"
        case .beeNest: "hexagon.fill"
        case .lightningRod: "bolt.fill"
        case .spawner: "cube.transparent"
        case .unopenedLoot: "shippingbox.fill"
        case .other: "scope"
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
        case .spawner: 0x223042
        case .unopenedLoot: 0x9B6717
        case .other: 0x566573
        }
    }

    /// Beds, workstations, bee nests and spawners number in the hundreds or thousands (558 beds and
    /// 11,296 spawners in Ryan's Realm), so they start hidden.
    var isShownByDefault: Bool { [.portal, .bell, .lodestone].contains(self) }

    static let professions = ["armorer", "butcher", "cartographer", "cleric", "farmer", "fisherman", "fletcher",
                              "leatherworker", "librarian", "mason", "shepherd", "toolsmith", "weaponsmith"]

    static func group(for type: String) -> PlaceGroup {
        guard let name = ReadableName.vanillaPath(type) else { return .other }
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
    /// For Nether portals: the whole portal (its blocks), as grouped by ChunkseeKit.
    var portal: NetherPortal?
    /// For spawners: the mob it spawns, or `nil` when it's empty.
    var mob: String?
    /// The saved table identifies the unopened loot; it does not predict the future items.
    var lootTable: String?

    var name: String {
        let base = ReadableName.identifierPath(type)
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
        // Named by its mob, not its surroundings: a zombie spawner may be in a monster room or
        // placed by a player, so the player judges from the map (Ryan, 2026-10-13).
        case .spawner: return mob.map { String(localized: "\(ReadableName.from($0)) Spawner") } ?? String(localized: "Empty Spawner")
        case .unopenedLoot: return LootTableName.name(lootTable)
        case .other: return ReadableName.from(base)
        }
    }

    init(_ poi: PointOfInterest) {
        id = "\(poi.type)@\(poi.x),\(poi.y),\(poi.z)"
        type = poi.type
        group = PlaceGroup.group(for: poi.type)
        position = MapCoordinates.center(of: CGPoint(x: poi.x, y: poi.z))
        y = poi.y
        isClaimed = poi.freeTickets == 0 && (group == .bed || group == .workstation)
    }

    /// A monster spawner, from its block entity in the terrain (spawners aren't points of interest).
    init(_ spawner: Spawner) {
        id = "spawner@\(spawner.x),\(spawner.y),\(spawner.z)"
        type = "minecraft:mob_spawner"
        group = .spawner
        position = MapCoordinates.center(of: CGPoint(x: spawner.x, y: spawner.z))
        y = spawner.y
        isClaimed = false
        mob = spawner.mob
    }

    init?(unopened container: ItemContainer) {
        guard container.isSealedLoot else { return nil }
        id = container.uuid.map { "loot-entity:\($0.uuidString.lowercased())" }
            ?? "loot@\(container.isEntity ? "entity" : "block")@\(container.kind)@\(container.x),\(container.y),\(container.z)"
        type = container.kind
        group = .unopenedLoot
        position = MapCoordinates.center(of: CGPoint(x: container.x, y: container.z))
        y = container.y
        isClaimed = false
        lootTable = container.lootTable
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
    static func scan(_ dimension: ChunkseeKit.Dimension, cache: ScanCache = .off) async -> [PlaceMarker] {
        let reader = RegionReader(dimension: dimension, cache: cache)
        var blocks: [PointOfInterest] = []
        for region in reader.availableRegions {
            guard !Task.isCancelled else { break }
            blocks += await reader.facts(region)?.pointsOfInterest ?? []
        }
        await reader.close()
        return Task.isCancelled ? [] : markers(from: blocks, in: dimension.id)
    }

    static func markers(from blocks: [PointOfInterest], in dimension: String) -> [PlaceMarker] {
        // Portal blocks become one place per portal (ChunkseeKit owns the grouping rule).
        let others = blocks.filter { PlaceGroup.group(for: $0.type) != .portal }.map(PlaceMarker.init)
        let portals = NetherPortal.portals(from: blocks, in: dimension).map(PlaceMarker.init)
        return (others + portals).sorted { $0.id < $1.id }
    }
}

/// Where a portal leads, as the app shows it.
nonisolated enum PortalLinkStatus: Equatable, Sendable {
    /// Leads to a portal that leads back here.
    case linked
    /// Leads to a portal whose return goes elsewhere or would create a new portal.
    case oneWay
    /// No portal in range on the other side; the game would build a new one.
    case noPartner

    /// Unknown dimension scans stay distinct from known-empty lists.
    static func roundTrip(of portal: NetherPortal, portals: [String: [NetherPortal]]) -> NetherPortal.RoundTrip? {
        guard let target = NetherPortal.targetDimension(from: portal.dimension),
              let candidates = portals[target], let origins = portals[portal.dimension] else { return nil }
        return portal.roundTrip(into: candidates, returningThrough: origins)
    }

    static func status(of portal: NetherPortal, portals: [String: [NetherPortal]]) -> PortalLinkStatus? {
        switch roundTrip(of: portal, portals: portals) {
        case .twoWay?: .linked
        case .oneWay?: .oneWay
        case .wouldCreateNewPortal?: .noPartner
        case nil: nil
        }
    }
}

/// Where the selected Nether portal leads, and whether the link goes both ways, in the inspector.
struct PortalDetailView: View {
    let session: WorldSession
    let portal: NetherPortal

    var body: some View {
        let trip = session.presentation.roundTrip(for: portal)
        Form {
            Section {
                LabeledContent("Position") {
                    Text(Coordinates(CGPoint(x: portal.centerX, y: portal.centerZ), y: portal.minY), format: Coordinates.Style())
                        .monospacedDigit()
                }
            } header: {
                Label("Nether Portal", systemImage: PlaceGroup.portal.symbol).font(.headline)
            }
            Section {
                switch trip {
                case .twoWay(let target, _)?, .oneWay(let target, _, _)?:
                    Text("Leads to the portal in \(session.presentation.dimensionName(target.dimension)) at \(Coordinates.text(x: target.centerX, z: target.centerZ)).")
                    if case .oneWay(_, _, let returning)? = trip {
                        switch returning {
                        case .portal(let back, _):
                            Label("One-way: that portal leads back to a different one, at \(Coordinates.text(x: back.centerX, z: back.centerZ)).",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        case .wouldCreateNewPortal(let destination):
                            Label("One-way: returning through that portal would build a new one near \(Coordinates.text(x: Double(destination.x), z: Double(destination.z))).",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Button("Show the Other Side") { session.selection.show(target) }
                case .wouldCreateNewPortal(let destination)?:
                    Label("No portal in \(session.presentation.dimensionName(NetherPortal.targetDimension(from: portal.dimension) ?? "")) is close enough. Going through would make the game build a new one near \(Coordinates.text(x: Double(destination.x), z: Double(destination.z))).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case nil:
                    if session.presentation.isWaitingForPortalLink(portal) {
                        ProgressView("Reading portal links…").controlSize(.small)
                    } else {
                        Text("Portal links aren’t available for this dimension.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Link")
            } footer: {
                if trip != nil {
                    Text("Predicted with Minecraft’s linking rule from the portal’s bottom center.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
