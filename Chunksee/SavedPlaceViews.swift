import ChunkseeKit
import SwiftUI

struct SavedPlacesSection: View {
    let session: WorldSession

    var body: some View {
        Section("Saved Places") {
            ForEach(session.annotations.listedPlaces) { place in
                VStack(alignment: .leading, spacing: 2) {
                    Label(place.name, systemImage: MarkerStyle.savedPlaceSymbol)
                    Text(Coordinates.text(place.position))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .tag(SidebarItem.savedPlace(place.id))
                .id(SidebarItem.savedPlace(place.id))
                .selectionDisabled(!session.annotations.canVisit(place))
                .contextMenu {
                    SavedPlaceMenu(session: session, place: place, map: session.map)
                }
            }
            Button("Save Place…", systemImage: "mappin.and.ellipse") { session.annotations.savePlace() }
                .buttonStyle(.plain)
                .disabled(session.map == nil)
                .help("Save the location at the center of the map")
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
            Text(Coordinates.text(draft.position, dimension: session.presentation.dimensionName(draft.dimension)))
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
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = draft.existingID {
            session.savedPlaces.rename(id, to: name)
        } else {
            session.savedPlaces.add(name: name, dimension: draft.dimension, at: draft.position)
        }
        dismiss()
    }
}
