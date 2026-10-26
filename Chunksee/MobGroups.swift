import SwiftUI
import ChunkseeIndex

/// Type names stay compact; saved counts and appearance choices belong in the inspector.
struct MobGroups: View {
    let session: WorldSession
    let catalog: MobTypes
    @Binding var expanded: Set<String>
    let rowsReady: () -> Void

    var body: some View {
        ForEach(catalog.kinds.map { (id: SidebarItem.mobType($0.id), kind: $0) }, id: \.id) { row in
            MobTypeGroup(session: session, catalog: catalog, kind: row.kind, isExpanded: Binding {
                expanded.contains(row.kind.id)
            } set: {
                if $0 { expanded.insert(row.kind.id) } else { expanded.remove(row.kind.id) }
            }, rowsReady: rowsReady)
        }
    }
}

private struct MobTypeGroup: View {
    let session: WorldSession
    let catalog: MobTypes
    let kind: MobTypes.Kind
    @Binding var isExpanded: Bool
    let rowsReady: () -> Void
    @State private var loaded: (request: Request, rows: [Row])?

    private struct Request: Equatable {
        let revision: UUID
        let species: String
        let origin: CGPoint
    }

    private struct Row: Identifiable {
        let marker: CreatureMarker
        var id: SidebarItem { .mobCreature(marker.id) }
    }

    var body: some View {
        let request = isExpanded ? Request(revision: catalog.revision, species: kind.id, origin: session.presentation.spawnPoint) : nil
        let rows = loaded?.request == request ? loaded?.rows ?? [] : []
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(rows) { row in
                MobLocationLabel(marker: row.marker)
                    .tag(row.id)
                    .repeatSidebarSelection(row.id, in: session.selection)
                    .help(LocationAvailability.available.help)
                    .locationMenu(session: session, position: row.marker.position,
                                  dimension: session.selectedDimensionID, y: row.marker.yCoordinate)
            }
        } label: {
            MapVisibilityRow(isShown: Binding {
                session.visibility.mobTypes.contains(kind.id)
            } set: {
                if $0 { session.visibility.mobTypes.insert(kind.id) }
                else { session.visibility.mobTypes.remove(kind.id) }
            }) {
                Label(kind.name, systemImage: CreatureGroup.mob.symbol)
            }
        }
        .tag(SidebarItem.mobType(kind.id))
        .task(id: request) {
            guard let request, loaded?.request != request,
                  let markers = try? await catalog.nearest(kind.id, to: request.origin), !Task.isCancelled else { return }
            loaded = (request, markers.map { Row(marker: $0) })
        }
        .onChange(of: loaded?.request) { rowsReady() }
    }
}

struct MobTypeDetails: View {
    let session: WorldSession
    let kind: MobTypes.Kind
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved Mobs", value: kind.count.formatted(.number.locale(locale)))
                Text("These positions come from the last save. Mobs may move or disappear when the world is played.")
                    .foregroundStyle(.secondary)
            } header: {
                InspectorHeading(title: Text(kind.name), symbol: CreatureGroup.mob.symbol)
            }
            Section("Appearances") {
                Picker("Show on Map", selection: Binding {
                    session.visibility.appearance(for: kind)
                } set: { appearance in
                    session.visibility.mobAppearances[kind.id] = appearance
                    session.visibility.mobTypes.insert(kind.id)
                }) {
                    Text("All Appearances").tag(Optional<MobAppearance>.none)
                    ForEach(kind.variants) { variant in
                        Text(variant.appearance.name(for: kind.id)).tag(Optional(variant.appearance))
                    }
                }
                ForEach(kind.variants) { variant in
                    LabeledContent(variant.appearance.name(for: kind.id), value: variant.count.formatted(.number.locale(locale)))
                }
            }
        }
        .formStyle(.grouped)
    }
}
