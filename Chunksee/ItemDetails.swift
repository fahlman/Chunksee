import ChunkseeKit
import SwiftUI

/// Selection resolves the item; all entry points show this same native inspector.
struct WorldInspector: View {
    let session: WorldSession
    @Environment(\.locale) private var locale

    var body: some View {
        switch session.selection.inspectorItem {
        case .worldInfo?: WorldInfoView(session: session)
        case .storage?: StorageView(session: session)
        case .player(let player)?: PlayerDetailView(session: session, player: player).id(player.uuid)
        case .creature(let marker)?: CreatureDetailView(session: session, marker: marker).id(marker.id)
        case .mobType(let kind)?: MobTypeDetails(session: session, kind: kind)
        case .inGameMap(let map)?: InGameMapDetailView(session: session, map: map).id(map.id)
        case .place(let marker)?:
            if let portal = marker.portal {
                PortalDetailView(session: session, portal: portal)
            } else {
                LocationDetails(session: session, title: Text(marker.name), symbol: marker.group.symbol,
                                destination: destination(marker.position, y: marker.yCoordinate)) {
                    switch marker.group {
                    case .spawner:
                        LabeledContent("Spawns", value: marker.mob.map { ReadableName.from($0) } ?? String(localized: "Nothing"))
                    case .bed, .workstation:
                        LabeledContent("Claimed by a Villager", value: marker.isClaimed ? String(localized: "Yes") : String(localized: "No"))
                    case .unopenedLoot:
                        LabeledContent("Container", value: ReadableName.from(marker.type))
                        Text("The contents have not been generated yet.").foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                }
            }
        case .structure(let marker)?:
            LocationDetails(session: session, title: Text(marker.name), symbol: marker.group.symbol,
                            destination: destination(marker.position, y: marker.yCoordinate)) {
                LabeledContent("Width", value: CountedText.blocks.locale(locale).format(Double(marker.bounds.width)))
                LabeledContent("Depth", value: CountedText.blocks.locale(locale).format(Double(marker.bounds.height)))
                if let room = marker.portalRoom {
                    LocationRow(title: Text("End Portal Room"), session: session, destination: destination(room))
                }
            }
        case .biome(let area)?:
            LocationDetails(session: session, title: Text(area.group.name), symbol: area.group.symbol,
                            destination: destination(area.position)) {
                LabeledContent("Area", value: area.name)
            }
        case .savedPlace(let place)?:
            LocationDetails(session: session, title: Text(place.name), symbol: MarkerStyle.savedPlaceSymbol,
                            destination: MapDestination(coordinates: Coordinates(place.position), dimension: place.dimension)) {}
        case .hit(let hit)?:
            LocationDetails(session: session, title: Text(hit.title), symbol: MarkerStyle.search.symbol.name,
                            destination: hit.position.map {
                                MapDestination(coordinates: Coordinates($0, y: hit.y.map(Double.init)), dimension: hit.dimension)
                            }) {}
        case nil: EmptyView()
        }
    }

    private func destination(_ position: CGPoint, y: Double? = nil) -> MapDestination {
        MapDestination(coordinates: Coordinates(position, y: y), dimension: session.selectedDimensionID)
    }
}

/// The same heading, location actions and form layout for every simple location inspector.
private struct LocationDetails<Details: View>: View {
    let session: WorldSession
    let title: Text
    let symbol: String
    let destination: MapDestination?
    @ViewBuilder var details: Details

    var body: some View {
        Form {
            Section {
                if let destination {
                    LocationRow(session: session, destination: destination, showsDimension: true)
                } else {
                    LabeledContent("Location", value: String(localized: "Location unknown"))
                }
                details
            } header: {
                InspectorHeading(title: title, symbol: symbol)
            }
            SelectedSearchSection(session: session)
        }
        .formStyle(.grouped)
    }
}

/// A search keeps its source and matching contents even when it opens a player's or pet's details.
struct SelectedSearchSection: View {
    let session: WorldSession

    var body: some View {
        if let hit = session.selection.selectedSearchHit {
            Section("Search Result") {
                switch hit.source {
                case .inventory, .enderChest: LabeledContent("Found In", value: hit.title)
                default: EmptyView()
                }
                if hit.items.isEmpty {
                    Text(hit.detail).textSelection(.enabled)
                } else {
                    ForEach(Array(hit.items.enumerated()), id: \.offset) { _, item in
                        ItemLabel(id: item.id, title: Text(item.text))
                            .textSelection(.enabled)
                    }
                }
                if case .enderChest = hit.source {
                    Text("An Ender Chest has no single location.").foregroundStyle(.secondary)
                }
            }
        }
    }
}
