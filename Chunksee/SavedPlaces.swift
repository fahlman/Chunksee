import CoreGraphics
import Foundation
import Observation

nonisolated struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var dimension: String
    var x: Int32
    var z: Int32

    var position: CGPoint { CGPoint(x: Int(x), y: Int(z)) }
    var mapPosition: CGPoint { MapCoordinates.center(of: position) }
}

/// Annotations live in the app's preferences, never in the read-only world folder.
@Observable
final class SavedPlaces {
    private(set) var all: [SavedPlace]
    private let settings: WorldSettings

    init(settings: WorldSettings) {
        self.settings = settings
        all = settings.savedPlaces
    }

    @discardableResult
    func add(name: String, dimension: String, at point: CGPoint) -> SavedPlace? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let coordinates = MapCoordinates(point: point) else { return nil }
        let place = SavedPlace(name: name, dimension: dimension, x: coordinates.x, z: coordinates.z)
        all.append(place)
        persist()
        return place
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = name
        persist()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        persist()
    }

    private func persist() { settings.savePlaces(all) }
}

nonisolated struct SavedPlaceDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var name: String
    var dimension: String
    var position: CGPoint
}
