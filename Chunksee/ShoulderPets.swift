import ChunkseeKit
import Foundation
import SwiftUI

/// A carried creature keeps its saved owner, but only its carrier can supply its current location.
nonisolated struct ShoulderPet: Identifiable, Sendable {
    let id: String
    let carrier: UUID
    let creature: Creature
    let location: PlayerInfo.Location?

    var name: String { creature.displayName }

    init(creature: Creature, carrier: PlayerInfo, index: Int) {
        self.creature = creature
        self.carrier = carrier.uuid
        location = PlayerPresentation.position(of: carrier)
        id = creature.uuid.map { "creature:\($0.uuidString.lowercased())" }
            ?? "shoulder:\(carrier.uuid.uuidString.lowercased()):\(index)"
    }

    var marker: CreatureMarker? {
        guard let location else { return nil }
        var located = creature
        located.x = location.x
        located.y = location.y
        located.z = location.z
        guard var marker = CreatureMarker(located, dimension: location.dimension) else { return nil }
        marker.id = id
        marker.carrier = carrier
        return marker
    }
}

extension SearchIndex {
    /// Player and entity files may be saved separately. A carried UUID must not also appear at
    /// its stale region position, including when its carrier cannot currently be located.
    func including(_ pets: [ShoulderPet]) -> SearchIndex {
        let carriedIDs = Set(pets.map(\.id))
        let located = Dictionary(grouping: pets.compactMap(\.marker), by: \.dimension)
        var result = self
        for (dimension, part) in dimensions {
            let retained = part.creatures.filter { !carriedIDs.contains($0.id) }
            let additions = located[dimension] ?? []
            guard retained.count != part.creatures.count || !additions.isEmpty else { continue }
            // Reuse the existing point collection, so map, sidebar, search and links agree.
            result.dimensions[dimension]?.creatures = (retained + additions).sorted { $0.id < $1.id }
        }
        return result
    }
}

/// Even an unlocatable carrier retains its birds here; no mounting coordinates are displayed.
struct ShoulderPetsSection: View {
    let session: WorldSession
    let playerID: UUID

    var body: some View {
        let pets = session.resources.playerSnapshot.shoulderPets.filter { $0.carrier == playerID }
        if !pets.isEmpty {
            Section("On Shoulders") {
                ForEach(pets) { pet in
                    DisclosureGroup {
                        CreatureDetailSections(session: session, creature: pet.creature) {
                            EmptyView()
                        } location: {
                            if pet.location == nil {
                                Text("Location unavailable").foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Label(pet.name, systemImage: "pawprint.fill")
                    }
                }
            }
        }
    }
}
