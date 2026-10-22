import ChunkseeIndex
import ChunkseeKit
import SwiftUI

/// A kind of map marker that the sidebar lists, and can show or hide.
nonisolated protocol MapLayerGroup: Hashable {
    var name: String { get }
    var symbol: String { get }
}

/// A marker the sidebar lists under its group.
nonisolated protocol MapLayerMarker: Identifiable where ID == String {
    associatedtype Group: MapLayerGroup
    var group: Group { get }
    var name: String { get }
    var position: CGPoint { get }
    /// Saved Y for map and sidebar coordinate commands; nil uses the map's terrain.
    var yCoordinate: Double? { get }
    /// What a search filter such as `structure:` matches: the name and kind, plus anything else
    /// that identifies the marker.
    var searchText: String { get }
}

extension MapLayerMarker {
    var searchText: String { name + " " + group.name }
}

extension StructureGroup: MapLayerGroup {}
extension PlaceGroup: MapLayerGroup {}
extension CreatureGroup: MapLayerGroup {}
extension StructureMarker: MapLayerMarker {
    var yCoordinate: Double? { y.map(Double.init) }
    var searchText: String { name + " " + group.name + " " + structureID }
}
extension PlaceMarker: MapLayerMarker {
    var yCoordinate: Double? { Double(y) }
    var searchText: String { [name, group.name, type, mob ?? "", lootTable ?? ""].joined(separator: " ") }
}
extension CreatureMarker: MapLayerMarker {
    var yCoordinate: Double? { creature.y }
    nonisolated var searchText: String { name + " " + group.name + " " + ReadableName.from(creature.id) + " " + creature.id }
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

    var body: some View {
        let byGroup = Dictionary(grouping: markers, by: \.group)
        let groups = Set(byGroup.keys).union(allGroups).sorted { $0.name < $1.name }
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
                        LocationLabel(title: Text(row.marker.name)) {
                            Image(systemName: row.marker.group.symbol)
                        }
                        .tag(row.id)
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
            Label(CountedText.label(group.name, count: count, locale: locale), systemImage: group.symbol)
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

/// One world dimension's layer controls, remembered between launches in `defaults`.
@Observable
final class LayerVisibility {
    var structures: Set<StructureGroup> { didSet { save(structures.map(\.rawValue), Keys.structures) } }
    var places: Set<PlaceGroup> { didSet { save(places.map(\.rawValue), Keys.places) } }
    var creatures: Set<CreatureGroup> { didSet { save(creatures.map(\.rawValue), Keys.creatures) } }
    /// None at first: outlining every biome would cover the map.
    var biomes: Set<BiomeGroup> { didSet { save(biomes.map(\.id), Keys.biomes) } }
    var hiddenPlayers: Set<UUID> { didSet { save(hiddenPlayers.map(\.uuidString), Keys.hiddenPlayers) } }
    /// Chunk and region lines; off at first.
    var showsGrid: Bool { didSet { saveValue(showsGrid, Keys.showsGrid) } }
    var showsSavedPlaces: Bool { didSet { saveValue(showsSavedPlaces, Keys.showsSavedPlaces) } }
    var showsWorldBorder: Bool { didSet { saveValue(showsWorldBorder, Keys.showsWorldBorder) } }

    private let settings: WorldSettings
    private let dimension: String?
    private typealias Keys = WorldSettings.Layer

    init(settings: WorldSettings, dimension: String?) {
        self.settings = settings
        self.dimension = dimension
        let previous = settings.layers(for: dimension)
        let values = previous ?? settings.legacyLayers
        func saved<Group: RawRepresentable & CaseIterable & Sendable>(_ key: Keys, default isShown: (Group) -> Bool) -> Set<Group> where Group.RawValue == String {
            guard let names = values[key] as? [String] else { return Set(Group.allCases.filter(isShown)) }
            return Set(names.compactMap(Group.init(rawValue:)))
        }
        structures = saved(Keys.structures, default: \.isShownByDefault)
        places = saved(Keys.places, default: \.isShownByDefault)
        creatures = saved(Keys.creatures, default: \.isShownByDefault)
        biomes = Set((values[Keys.biomes] as? [String] ?? []).map(BiomeGroup.init(id:)))
        hiddenPlayers = Set((values[Keys.hiddenPlayers] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        showsGrid = values[Keys.showsGrid] as? Bool ?? false
        showsSavedPlaces = values[Keys.showsSavedPlaces] as? Bool ?? true
        showsWorldBorder = values[Keys.showsWorldBorder] as? Bool ?? true
        if previous == nil {
            write([
                Keys.structures: structures.map(\.rawValue).sorted(), Keys.places: places.map(\.rawValue).sorted(),
                Keys.creatures: creatures.map(\.rawValue).sorted(), Keys.biomes: biomes.map(\.id).sorted(),
                Keys.hiddenPlayers: hiddenPlayers.map(\.uuidString).sorted(), Keys.showsGrid: showsGrid,
                Keys.timeSpent: false, Keys.showsSavedPlaces: showsSavedPlaces,
                Keys.showsWorldBorder: showsWorldBorder,
            ])
        }
    }

    /// HeatMapLayer owns the live flag; these accessors only restore and persist its value.
    var rememberedTimeSpent: Bool { settings.layers(for: dimension)?[.timeSpent] as? Bool ?? false }
    func rememberTimeSpent(_ shown: Bool) { saveValue(shown, .timeSpent) }

    /// SlimeChunkLayer owns the live flag, just as HeatMapLayer owns Time Spent.
    var rememberedSlimeChunks: Bool { settings.layers(for: dimension)?[.slimeChunks] as? Bool ?? false }
    func rememberSlimeChunks(_ shown: Bool) { saveValue(shown, .slimeChunks) }

    private func save(_ names: [String], _ key: Keys) { saveValue(names.sorted(), key) }
    private func saveValue(_ value: Any, _ key: Keys) { write([key: value]) }
    private func write(_ values: [Keys: Any]) { settings.saveLayers(values, for: dimension) }
}
