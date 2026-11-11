import ChunkseeIndex
import ChunkseeKit
import SwiftUI

/// A kind of map marker that the sidebar lists, and can show or hide.
nonisolated protocol MapLayerGroup: Hashable {
    var id: String { get }
    func name(in gameNames: GameNames) -> String
    var symbol: String { get }
}

/// A marker the sidebar lists under its group.
nonisolated protocol MapLayerMarker: Identifiable where ID == String {
    associatedtype Group: MapLayerGroup
    var group: Group { get }
    func name(in gameNames: GameNames) -> String
    var position: CGPoint { get }
    /// Saved Y for map and sidebar coordinate commands; nil uses the map's terrain.
    var yCoordinate: Double? { get }
    /// What a search filter such as `structure:` matches: the name and kind, plus anything else
    /// that identifies the marker.
    func searchText(in gameNames: GameNames) -> String
}

extension MapLayerMarker {
    nonisolated func searchText(in gameNames: GameNames) -> String { name(in: gameNames) + " " + group.name(in: gameNames) }
}

extension StructureGroup: MapLayerGroup {
    nonisolated var id: String { rawValue }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.group(self) }
}
extension PlaceGroup: MapLayerGroup {
    nonisolated var id: String { rawValue }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.group(self) }
}
extension CreatureGroup: MapLayerGroup {
    nonisolated var id: String { rawValue }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.group(self) }
}
extension StructureMarker: MapLayerMarker {
    var yCoordinate: Double? { y.map(Double.init) }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.structure(structureID) }
    nonisolated func searchText(in gameNames: GameNames) -> String {
        name(in: gameNames) + " " + group.name(in: gameNames) + " " + structureID
    }
}
extension PlaceMarker: MapLayerMarker {
    var yCoordinate: Double? { Double(y) }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.place(self) }
    nonisolated func searchText(in gameNames: GameNames) -> String {
        [name(in: gameNames), group.name(in: gameNames), type, mob ?? "", lootTable ?? ""].joined(separator: " ")
    }
}
extension CreatureMarker: MapLayerMarker {
    var yCoordinate: Double? { creature.y }
    nonisolated func name(in gameNames: GameNames) -> String { gameNames.creature(creature) }
    nonisolated func searchText(in gameNames: GameNames) -> String { gameNames.creatureSearchText(self) }
}

/// Sidebar groups for one layer (structures, places, creatures or biomes). Groups are listed
/// by name; each expands into a list, nearest to `origin` first, whose rows are tagged with `item`
/// for the sidebar's selection. With `shown`, each group can be shown or hidden on the map.
/// `allGroups` are listed even when they have no markers, with a count of 0.
struct LayerGroups<Marker: MapLayerMarker>: View {
    let session: WorldSession
    let markers: [Marker]
    let origin: CGPoint
    var shown: Binding<Set<Marker.Group>>?
    var allGroups: [Marker.Group] = []
    let item: (Marker) -> SidebarItem
    @Binding var expandedGroups: Set<Marker.Group>
    @Environment(\.locale) private var locale
    @Environment(\.gameNames) private var gameNames

    var body: some View {
        let byGroup = Dictionary(grouping: markers, by: \.group)
        let groups = gameNames.layerGroups(Set(byGroup.keys).union(allGroups))
        ForEach(groups, id: \.self) { group in
            if byGroup[group] == nil {
                row(group, count: 0)
            } else {
                DisclosureGroup(isExpanded: Binding {
                    expandedGroups.contains(group)
                } set: {
                    if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                }) {
                    // The collection owns the same identity used by selection and scrolling.
                    // An inner .id adds a dynamic row-list transformation for every marker.
                    ForEach(nearestFirst(byGroup[group] ?? []).map { (id: item($0), marker: $0) }, id: \.id) { row in
                        Group {
                            if let creature = row.marker as? CreatureMarker {
                                MobLocationLabel(marker: creature)
                            } else {
                                LocationLabel(title: Text(row.marker.name(in: gameNames))) {
                                    Image(systemName: row.marker.group.symbol)
                                }
                            }
                        }
                        .tag(row.id)
                        .repeatSidebarSelection(row.id, in: session.selection)
                        .help(LocationAvailability.available.help)
                        .locationMenu(session: session, position: row.marker.position,
                                      dimension: session.selectedDimensionID, y: row.marker.yCoordinate)
                    }
                } label: {
                    row(group, count: byGroup[group]?.count ?? 0)
                }
            }
        }
    }

    private func row(_ group: Marker.Group, count: Int) -> some View {
        let visibility = shown.map { shown in
            Binding {
                shown.wrappedValue.contains(group)
            } set: {
                if $0 { shown.wrappedValue.insert(group) } else { shown.wrappedValue.remove(group) }
            }
        }
        return MapVisibilityRow(isShown: visibility) {
            Label(CountedText.label(group.name(in: gameNames), count: count, locale: locale), systemImage: group.symbol)
        }
    }

    private func nearestFirst(_ markers: [Marker]) -> [Marker] {
        markers.sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
    }
}

/// Every eye row shares spacing, accessibility and menu placement; callers add only their own commands.
struct MapVisibilityRow<Content: View, Commands: View>: View {
    private let isShown: Binding<Bool>?
    private let content: Content
    private let commands: Commands

    init(isShown: Binding<Bool>?, @ViewBuilder content: () -> Content, @ViewBuilder commands: () -> Commands) {
        self.isShown = isShown
        self.content = content()
        self.commands = commands()
    }

    init(isShown: Binding<Bool>?, @ViewBuilder content: () -> Content) where Commands == EmptyView {
        self.init(isShown: isShown, content: content, commands: { EmptyView() })
    }

    var body: some View {
        HStack {
            content
            Spacer(minLength: 0)
            if let isShown { VisibilityButton(isShown: isShown).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isShown?.wrappedValue == true ? "Shown on Map" : "Hidden on Map", isEnabled: isShown != nil)
        // A button inside a native disclosure label can also run when that label is expanded.
        // Expose the same command as a named action, leaving the primary row action to the List.
        .accessibilityActions {
            if let isShown { VisibilityCommand(isShown: isShown) }
        }
        .contextMenu {
            Section { if let isShown { VisibilityCommand(isShown: isShown) } }
            Section { commands }
        }
    }
}

/// One action/label for eye buttons and native context menus. SwiftUI exposes the button action
/// on combined accessibility rows too.
struct VisibilityCommand: View {
    @Binding var isShown: Bool
    var showsCurrentState = false

    var body: some View {
        let openEye = showsCurrentState ? isShown : !isShown
        Button(isShown ? "Hide on Map" : "Show on Map", systemImage: openEye ? "eye" : "eye.slash") { isShown.toggle() }
    }
}

/// The eye button that shows or hides something on the map.
struct VisibilityButton: View {
    @Binding var isShown: Bool

    var body: some View {
        VisibilityCommand(isShown: $isShown, showsCurrentState: true)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isShown ? .primary : .tertiary)
    }
}
