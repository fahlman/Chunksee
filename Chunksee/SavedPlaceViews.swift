import ChunkseeKit
import SwiftUI

struct SavedPlacesGroup: View {
    let session: WorldSession
    @Binding var isExpanded: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var visibility = session.visibility
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(session.annotations.listedPlaces) { place in
                let availability = session.routing.availability(of: Coordinates(place.position), in: place.dimension)
                LocationLabel(title: Text(place.name), isDimmed: !availability.canNavigate) {
                    Image(systemName: MarkerStyle.savedPlaceSymbol)
                }
                .tag(SidebarItem.savedPlace(place.id))
                .id(SidebarItem.savedPlace(place.id))
                .help(availability.help)
                .contextMenu {
                    SavedPlaceMenu(session: session, place: place)
                }
            }
            Button("Save Place…", systemImage: "mappin.and.ellipse") { session.annotations.savePlace() }
                .buttonStyle(.plain)
                .disabled(session.map == nil)
                .help("Save the location at the center of the map")
        } label: {
            MapVisibilityRow(isShown: $visibility.showsSavedPlaces) {
                Label(CountedText.label(String(localized: "Saved Places", locale: locale),
                                        count: session.annotations.listedPlaces.count, locale: locale),
                      systemImage: MarkerStyle.savedPlaceSymbol)
            }
        }
    }
}

/// The annotations model owns the draft; name editing cannot move or alter the world.
struct SavedPlaceEditor: View {
    let session: WorldSession
    let draft: SavedPlaceDraft
    @State private var name: String
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(session: WorldSession, draft: SavedPlaceDraft) {
        self.session = session
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.existingID == nil ? "Save Place" : "Rename Place").font(.headline)
            CoordinateText(Coordinates(draft.position), dimension: session.presentation.dimensionName(draft.dimension))
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("saved-place-name")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onSubmit(save)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !session.isClosed else { dismiss(); return }
        if session.annotations.commit(draft, name: name) { dismiss() }
    }
}
