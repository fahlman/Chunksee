import Foundation
import ChunkseeKit
import SwiftUI

struct LinkedPetsSection: View {
    let session: WorldSession
    let playerID: UUID
    @Environment(\.gameNames) private var gameNames

    var body: some View {
        let pets = session.presentation.linkedPets(to: playerID)
        if !pets.isEmpty {
            Section("Linked Pets") {
                ForEach(pets) { pet in
                    let availability = session.routing.availability(of: Coordinates(pet.position, y: pet.creature.y), in: pet.dimension)
                    Button { session.selection.showLinkedPet(pet, ownedBy: playerID) } label: {
                        LocationLabel(title: Text(gameNames.creature(pet.creature)), isDimmed: !availability.canNavigate) {
                            Image(systemName: pet.group.symbol)
                        }
                    }
                    .accessibilityIdentifier("linked-pet-\(pet.id)")
                    .help(availability.help)
                    .locationMenu(session: session, position: pet.position, dimension: pet.dimension,
                                  y: pet.creature.y)
                }
            }
        }
    }
}
