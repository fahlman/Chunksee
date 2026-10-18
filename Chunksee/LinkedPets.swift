import Foundation
import ChunkseeKit
import SwiftUI

extension WorldSession {
    /// This world's currently indexed pets, matched by saved owner UUID rather than name.
    func linkedPets(to playerID: UUID) -> [CreatureMarker] {
        search.index.creatures.map(\.value).filter { $0.creature.owner == playerID }
            .sorted { ($0.dimension, $0.name, $0.id) < ($1.dimension, $1.name, $1.id) }
    }

}

struct LinkedPetsSection: View {
    let session: WorldSession
    let playerID: UUID

    var body: some View {
        let pets = session.linkedPets(to: playerID)
        if !pets.isEmpty {
            Section("Linked Pets") {
                ForEach(pets) { pet in
                    Button { session.showLinkedPet(pet, ownedBy: playerID) } label: {
                        VStack(alignment: .leading) {
                            Label(pet.name, systemImage: "pawprint.fill")
                            Text(Coordinates.text(pet.position, y: pet.creature.y, dimension: session.dimensionName(pet.dimension)))
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
