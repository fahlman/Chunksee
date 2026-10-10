import SwiftUI

/// A kind of map marker that the sidebar lists, and can show or hide.
protocol MapLayerGroup: Hashable {
    var name: String { get }
    var symbol: String { get }
}

/// A marker the sidebar lists under its group.
protocol MapLayerMarker: Identifiable where ID == String {
    associatedtype Group: MapLayerGroup
    var group: Group { get }
    var name: String { get }
    var position: CGPoint { get }
}

extension StructureGroup: MapLayerGroup {}
extension PlaceGroup: MapLayerGroup {}
extension CreatureGroup: MapLayerGroup {}
extension StructureMarker: MapLayerMarker {}
extension PlaceMarker: MapLayerMarker {}
extension CreatureMarker: MapLayerMarker {}

/// A sidebar section for one layer (structures, places, creatures or biomes). Groups are listed
/// by name; each expands into a list, nearest to `origin` first, and choosing an entry calls
/// `select`. With `shown`, each group can be shown or hidden on the map, and choosing an entry
/// shows its group.
struct LayerSection<Marker: MapLayerMarker>: View {
    let title: LocalizedStringKey
    let markers: [Marker]
    let origin: CGPoint
    var shown: Binding<Set<Marker.Group>>?
    let select: (Marker) -> Void
    @State private var isExpanded = true

    var body: some View {
        let byGroup = Dictionary(grouping: markers, by: \.group)
        if !byGroup.isEmpty {
            Section(title, isExpanded: $isExpanded) {
                ForEach(byGroup.keys.sorted { $0.name < $1.name }, id: \.self) { group in
                    DisclosureGroup {
                        ForEach(nearestFirst(byGroup[group] ?? [])) { marker in
                            Button {
                                shown?.wrappedValue.insert(group)
                                select(marker)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.name)
                                    Text(Coordinates.text(marker.position))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Show on the map")
                        }
                    } label: {
                        row(group, count: byGroup[group]?.count ?? 0)
                    }
                }
            }
        }
    }

    private func row(_ group: Marker.Group, count: Int) -> some View {
        HStack {
            Label("\(group.name) (\(count))", systemImage: group.symbol)
            Spacer()
            if let shown {
                VisibilityButton(isShown: Binding {
                    shown.wrappedValue.contains(group)
                } set: {
                    if $0 { shown.wrappedValue.insert(group) } else { shown.wrappedValue.remove(group) }
                })
            }
        }
    }

    private func nearestFirst(_ markers: [Marker]) -> [Marker] {
        markers.sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
    }
}

/// The eye button that shows or hides something on the map, in every sidebar layer and player row.
struct VisibilityButton: View {
    @Binding var isShown: Bool

    var body: some View {
        Button(isShown ? "Hide on Map" : "Show on Map", systemImage: isShown ? "eye" : "eye.slash") { isShown.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isShown ? .primary : .tertiary)
    }
}

/// Which layers and players the map shows, remembered between launches in `defaults`.
@Observable
final class LayerVisibility {
    var structures: Set<StructureGroup> { didSet { save(structures.map(\.rawValue), Keys.structures) } }
    var places: Set<PlaceGroup> { didSet { save(places.map(\.rawValue), Keys.places) } }
    var creatures: Set<CreatureGroup> { didSet { save(creatures.map(\.rawValue), Keys.creatures) } }
    /// None at first: outlining every biome would cover the map.
    var biomes: Set<BiomeGroup> { didSet { save(biomes.map(\.id), Keys.biomes) } }
    var hiddenPlayers: Set<UUID> { didSet { save(hiddenPlayers.map(\.uuidString), Keys.hiddenPlayers) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let structures = "shownStructureGroups"
        static let places = "shownPlaceGroups"
        static let creatures = "shownCreatureGroups"
        static let biomes = "shownBiomeGroups"
        static let hiddenPlayers = "hiddenPlayers"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func saved<Group: RawRepresentable & CaseIterable>(_ key: String, default isShown: (Group) -> Bool) -> Set<Group> where Group.RawValue == String {
            guard let names = defaults.stringArray(forKey: key) else { return Set(Group.allCases.filter(isShown)) }
            return Set(names.compactMap(Group.init(rawValue:)))
        }
        structures = saved(Keys.structures, default: \.isShownByDefault)
        places = saved(Keys.places, default: \.isShownByDefault)
        creatures = saved(Keys.creatures, default: \.isShownByDefault)
        biomes = Set((defaults.stringArray(forKey: Keys.biomes) ?? []).map(BiomeGroup.init(id:)))
        hiddenPlayers = Set((defaults.stringArray(forKey: Keys.hiddenPlayers) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func save(_ names: [String], _ key: String) {
        defaults.set(names.sorted(), forKey: key)
    }
}
