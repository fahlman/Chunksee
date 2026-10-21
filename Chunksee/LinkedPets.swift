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
                        LocationLabel(title: Text(pet.name)) {
                            Image(systemName: pet.group.symbol)
                        } caption: {
                            CoordinateText(Coordinates(pet.position, y: pet.creature.y),
                                           dimension: session.presentation.dimensionName(pet.dimension))
                        }
                    }
                    .accessibilityIdentifier("linked-pet-\(pet.id)")
                    .help("Show this pet on the map")
                    .locationMenu(session: session, position: pet.position, dimension: pet.dimension,
                                  y: pet.creature.y)
                }
            }
        }
    }
}
