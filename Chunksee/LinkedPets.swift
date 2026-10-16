import Foundation
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
                            Text("\(session.dimensionName(pet.dimension)): X \(Int(pet.creature.x.rounded(.down)))  Y \(Int(pet.creature.y.rounded(.down)))  Z \(Int(pet.creature.z.rounded(.down)))")
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
