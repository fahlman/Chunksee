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
                            Text(Coordinates.text(pet.position, y: pet.creature.y, dimension: session.presentation.dimensionName(pet.dimension)))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("linked-pet-\(pet.id)")
                    .help("Show this pet on the map")
                }
            }
        }
    }
}
