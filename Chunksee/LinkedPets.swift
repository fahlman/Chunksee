import Foundation
import ChunkseeKit
import SwiftUI

struct LinkedPetsSection: View {
    let session: WorldSession
    let playerID: UUID

    var body: some View {
        let pets = session.presentation.linkedPets(to: playerID)
        if !pets.isEmpty {
            Section("Linked Pets") {
                ForEach(pets) { pet in
                    Button { session.selection.showLinkedPet(pet, ownedBy: playerID) } label: {
                        VStack(alignment: .leading) {
                            Label(pet.name, systemImage: "pawprint.fill")
                            CoordinateText(Coordinates(pet.position, y: pet.creature.y),
                                           dimension: session.presentation.dimensionName(pet.dimension))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("linked-pet-\(pet.id)")
                    .help("Show this pet on the map")
                    .contextMenu {
                        LocationMenu(session: session, position: pet.position, dimension: pet.dimension,
                                     y: pet.creature.y)
                    }
                }
            }
        }
    }
}
