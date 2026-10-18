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
    var searchText: String { name + " " + group.name + " " + structureID }
}
extension PlaceMarker: MapLayerMarker {
    var searchText: String { [name, group.name, type, mob ?? ""].joined(separator: " ") }
}
extension CreatureMarker: MapLayerMarker {
    var searchText: String { name + " " + group.name + " " + ReadableName.from(creature.id) + " " + creature.id }
}

/// A sidebar section for one layer (structures, places, creatures or biomes). Groups are listed
/// by name; each expands into a list, nearest to `origin` first, whose rows are tagged with `item`
/// for the sidebar's selection. With `shown`, each group can be shown or hidden on the map.
/// `allGroups` are listed even when they have no markers, with a count of 0.
struct LayerSection<Marker: MapLayerMarker>: View {
    let title: LocalizedStringKey
    let markers: [Marker]
    let origin: CGPoint
    var shown: Binding<Set<Marker.Group>>?
    var allGroups: [Marker.Group] = []
    let item: (Marker) -> SidebarItem
    @Binding var isExpanded: Bool
    @Binding var expandedGroups: Set<Marker.Group>

    var body: some View {
        let byGroup = Dictionary(grouping: markers, by: \.group)
        let groups = Set(byGroup.keys).union(allGroups).sorted { $0.name < $1.name }
        if !groups.isEmpty {
            Section(title, isExpanded: $isExpanded) {
                ForEach(groups, id: \.self) { group in
                    if byGroup[group] == nil {
                        row(group, count: 0)
                    } else {
                        DisclosureGroup(isExpanded: Binding {
                            expandedGroups.contains(group)
                        } set: {
                            if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                        }) {
                            ForEach(nearestFirst(byGroup[group] ?? [])) { marker in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.name)
                                    Text(Coordinates.text(marker.position))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(item(marker))
                                .id(item(marker))
                                .help("Center the map on this location")
                            }
                        } label: {
                            row(group, count: byGroup[group]?.count ?? 0)
                        }
                    }
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
        return HStack {
            Label("\(group.name) (\(count))", systemImage: group.symbol)
            Spacer()
            if let visibility { VisibilityButton(isShown: visibility) }
        }
        .contextMenu { if let visibility { VisibilityCommand(isShown: visibility) } }
        .accessibilityActions { if let visibility { VisibilityCommand(isShown: visibility) } }
    }

    private func nearestFirst(_ markers: [Marker]) -> [Marker] {
        markers.sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
    }
}

/// One action/label for eye buttons, native context menus and combined rows' accessibility actions.
struct VisibilityCommand: View {
    @Binding var isShown: Bool

    var body: some View {
        Button(isShown ? "Hide on Map" : "Show on Map", systemImage: isShown ? "eye" : "eye.slash") { isShown.toggle() }
    }
}

/// The eye button that shows or hides something on the map.
struct VisibilityButton: View {
    @Binding var isShown: Bool

    var body: some View {
        VisibilityCommand(isShown: $isShown)
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

    private let defaults: UserDefaults
    private let worldKey: String
    private let dimension: String?

    private enum Keys {
        static let structures = "shownStructureGroups"
        static let places = "shownPlaceGroups"
        static let creatures = "shownCreatureGroups"
        static let biomes = "shownBiomeGroups"
        static let hiddenPlayers = "hiddenPlayers"
        static let showsGrid = "showsGrid"
        static let timeSpent = "showsTimeSpent"
        static let legacy = [structures, places, creatures, biomes, hiddenPlayers, showsGrid]
    }

    init(world: URL, dimension: String?, defaults: UserDefaults) {
        self.defaults = defaults
        let worldKey = Self.key(for: world)
        self.worldKey = worldKey
        self.dimension = dimension
        let previous = dimension.flatMap { defaults.dictionary(forKey: worldKey)?[$0] as? [String: Any] }
        // The previous app-wide choices seed a tab once; tab changes never write those keys.
        let values = previous ?? Dictionary(uniqueKeysWithValues: Keys.legacy.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        func saved<Group: RawRepresentable & CaseIterable & Sendable>(_ key: String, default isShown: (Group) -> Bool) -> Set<Group> where Group.RawValue == String {
            guard let names = values[key] as? [String] else { return Set(Group.allCases.filter(isShown)) }
            return Set(names.compactMap(Group.init(rawValue:)))
        }
        structures = saved(Keys.structures, default: \.isShownByDefault)
        places = saved(Keys.places, default: \.isShownByDefault)
        creatures = saved(Keys.creatures, default: \.isShownByDefault)
        biomes = Set((values[Keys.biomes] as? [String] ?? []).map(BiomeGroup.init(id:)))
        hiddenPlayers = Set((values[Keys.hiddenPlayers] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        showsGrid = values[Keys.showsGrid] as? Bool ?? false
        if previous == nil {
            write([
                Keys.structures: structures.map(\.rawValue).sorted(), Keys.places: places.map(\.rawValue).sorted(),
                Keys.creatures: creatures.map(\.rawValue).sorted(), Keys.biomes: biomes.map(\.id).sorted(),
                Keys.hiddenPlayers: hiddenPlayers.map(\.uuidString).sorted(), Keys.showsGrid: showsGrid,
                Keys.timeSpent: false,
            ])
        }
    }

    private static func key(for world: URL) -> String { "mapLayers." + world.standardizedFileURL.path }

    private var stored: [String: Any] {
        dimension.flatMap { defaults.dictionary(forKey: worldKey)?[$0] as? [String: Any] } ?? [:]
    }

    /// HeatMapLayer owns the live flag; these accessors only restore and persist its value.
    var rememberedTimeSpent: Bool { stored[Keys.timeSpent] as? Bool ?? false }
    func rememberTimeSpent(_ shown: Bool) { saveValue(shown, Keys.timeSpent) }

    private func save(_ names: [String], _ key: String) { saveValue(names.sorted(), key) }

    private func saveValue(_ value: Any, _ key: String) {
        var values = stored
        values[key] = value
        write(values)
    }

    private func write(_ values: [String: Any]) {
        guard let dimension else { return }
        // Read the current dictionary so another dimension's changes are retained.
        var dimensions = defaults.dictionary(forKey: worldKey) ?? [:]
        dimensions[dimension] = values
        defaults.set(dimensions, forKey: worldKey)
    }

    /// A native move keeps every dimension's settings under the moving world's new URL.
    func relocate(to world: URL) {
        let destination = Self.key(for: world)
        guard destination != worldKey, let moving = defaults.dictionary(forKey: worldKey) else { return }
        var merged = defaults.dictionary(forKey: destination) ?? [:]
        merged.merge(moving) { _, moving in moving }
        defaults.set(merged, forKey: destination)
        defaults.removeObject(forKey: worldKey)
    }
}
