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
        case .unopenedLoot: "gift.fill"
        case .other: "ellipsis.circle.fill"
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

    private var tagID: String? {
        switch self {
        case .workstation: "minecraft:acquirable_job_site"
        case .beeNest: "minecraft:bee_home"
        default: nil
        }
    }

    static var tagIDs: Set<String> { Set(allCases.compactMap(\.tagID)) }

    /// Presentation families use the world's composed POI tags. Unavailable membership does
    /// not turn into a second content inventory; every ungrouped saved record stays visible.
    struct Catalog: Sendable, Equatable {
        private var byID: [String: PlaceGroup] = [:]

        init(tags: [String: GameTag]) {
            // Keep one marker per saved point. Overlap follows the existing sidebar order.
            for group in PlaceGroup.allCases {
                guard let tag = group.tagID.flatMap({ tags[$0] }) else { continue }
                for member in tag.members where byID[member.id] == nil { byID[member.id] = group }
            }
        }

        func group(for type: String) -> PlaceGroup {
            guard let id = Identifier(type)?.description else { return .other }
            // These single-type display choices precede families. In particular, Kit already
            // groups portal blocks, so a tag must not create a second marker for each block.
            switch id {
            case "minecraft:nether_portal": return .portal
            case "minecraft:meeting": return .bell
            case "minecraft:lodestone": return .lodestone
            case "minecraft:home": return .bed
            case "minecraft:lightning_rod": return .lightningRod
            default: return byID[id] ?? .other
            }
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
            let job = ReadableName.from(type)
            return String(localized: "\(job)’s Workstation")
        case .beeNest:
            switch ReadableName.vanillaPath(type) {
            case "beehive": return String(localized: "Beehive")
            case "bee_nest": return String(localized: "Bee Nest")
            default: return ReadableName.from(type)
            }
        case .lightningRod: return String(localized: "Lightning Rod")
        // Named by its mob, not its surroundings: a zombie spawner may be in a monster room or
        // placed by a player, so the player judges from the map (Ryan, 2026-10-13).
        case .spawner: return mob.map { String(localized: "\(ReadableName.from($0)) Spawner") } ?? String(localized: "Empty Spawner")
        case .unopenedLoot: return LootTableName.name(lootTable)
        case .other: return ReadableName.from(base)
        }
    }

    init(_ poi: PointOfInterest, groups: PlaceGroup.Catalog = .init(tags: [:])) {
        id = "\(poi.type)@\(poi.x),\(poi.y),\(poi.z)"
        type = poi.type
        group = groups.group(for: poi.type)
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

/// Native place projections of the shared dimension index's points and grouped portals.
nonisolated enum PlacePresentation {
    static func markers(from blocks: [PointOfInterest], portals: [NetherPortal],
                        groups: PlaceGroup.Catalog = .init(tags: [:])) -> [PlaceMarker] {
        // Portal blocks become one place per portal (ChunkseeKit owns the grouping rule).
        let others = blocks.filter { groups.group(for: $0.type) != .portal }.map { PlaceMarker($0, groups: groups) }
        return (others + portals.map(PlaceMarker.init)).sorted { $0.id < $1.id }
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
    static func roundTrip(of portal: NetherPortal, portals: [String: [NetherPortal]],
                          dimensionTypes: [String: DimensionType], borders: [String: WorldBorder]) -> NetherPortal.RoundTrip? {
        guard let target = NetherPortal.targetDimension(from: portal.dimension),
              let returning = NetherPortal.targetDimension(from: target), let candidates = portals[target] else { return nil }
        if let origins = portals[returning] {
            return portal.roundTrip(into: candidates, returningThrough: origins, dimensionTypes: dimensionTypes, borders: borders)
        }
        switch portal.link(into: candidates, dimensionTypes: dimensionTypes, borders: borders) {
        case .portal(let destination, let block)?: return .returnUnknown(target: destination, block: block)
        case .wouldCreateNewPortal(let destination)?: return .wouldCreateNewPortal(destination: destination)
        case nil: return nil
        }
    }

    static func status(of portal: NetherPortal, portals: [String: [NetherPortal]],
                          dimensionTypes: [String: DimensionType], borders: [String: WorldBorder]) -> PortalLinkStatus? {
        switch roundTrip(of: portal, portals: portals, dimensionTypes: dimensionTypes, borders: borders) {
        case .twoWay?: .linked
        case .oneWay?: .oneWay
        case .wouldCreateNewPortal?: .noPartner
        case .returnUnknown?, nil: nil
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
                LocationRow(session: session,
                            destination: MapDestination(coordinates: Coordinates(CGPoint(x: portal.centerX, y: portal.centerZ), y: portal.minY),
                                                        dimension: portal.dimension))
            } header: {
                InspectorHeading(title: Text("Nether Portal"), symbol: PlaceGroup.portal.symbol)
            }
            SelectedSearchSection(session: session)
            Section {
                switch trip {
                case .twoWay(let target, _)?, .oneWay(let target, _, _)?, .returnUnknown(let target, _)?:
                    Text("Leads to the portal in \(target.dimension, format: session.presentation.dimensionNameStyle) at \(Coordinates.text(x: target.centerX, z: target.centerZ)).")
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
                    if case .returnUnknown? = trip {
                        Text("The return link is unknown.").foregroundStyle(.secondary)
                    }
                    Button("Show the Other Side") { session.selection.show(target) }
                        .locationMenu(session: session, position: CGPoint(x: target.centerX, y: target.centerZ),
                                      dimension: target.dimension, y: Double(target.minY))
                case .wouldCreateNewPortal(let destination)?:
                    Label("No portal in \(NetherPortal.targetDimension(from: portal.dimension) ?? "", format: session.presentation.dimensionNameStyle) is close enough. Going through would make the game build a new one near \(Coordinates.text(x: Double(destination.x), z: Double(destination.z))).",
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
