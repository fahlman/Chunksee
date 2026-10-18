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
    private let defaults: UserDefaults
    private let key: String

    init(world: URL, defaults: UserDefaults) {
        self.defaults = defaults
        key = Self.key(for: world)
        all = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
    }

    private static func key(for world: URL) -> String { "savedPlaces." + world.standardizedFileURL.path }

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

    /// Native document moves retain the world's annotations under its new folder URL.
    func relocate(to world: URL) {
        let newKey = Self.key(for: world)
        guard newKey != key else { return }
        let destination = SavedPlaces(world: world, defaults: defaults)
        let ids = Set(destination.all.map(\.id))
        destination.all.append(contentsOf: all.filter { !ids.contains($0.id) })
        destination.persist()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated struct SavedPlaceDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var name: String
    var dimension: String
    var position: CGPoint
}
