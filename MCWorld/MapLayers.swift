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
                                    Text("X \(Int(marker.position.x.rounded(.down)))  Z \(Int(marker.position.y.rounded(.down)))")
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
                let isShown = shown.wrappedValue.contains(group)
                Button(isShown ? "Hide on Map" : "Show on Map", systemImage: isShown ? "eye" : "eye.slash") {
                    if isShown { shown.wrappedValue.remove(group) } else { shown.wrappedValue.insert(group) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(isShown ? .primary : .tertiary)
            }
        }
    }

    private func nearestFirst(_ markers: [Marker]) -> [Marker] {
        markers.sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
    }
}
