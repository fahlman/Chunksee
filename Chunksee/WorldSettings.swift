import CoreGraphics
import Foundation

/// One world's persisted presentation, shared by its dimension documents. Feature models own
/// live state; its bookmark identity keeps this storage independent of the folder's path.
final class WorldSettings {
    private let defaults: UserDefaults
    let worldID: UUID
    private let key: String

    convenience init(folder: WorldFolders.Folder, defaults: UserDefaults) {
        self.init(id: folder.id, defaults: defaults)
    }

    init(id: UUID, defaults: UserDefaults) {
        self.defaults = defaults
        worldID = id
        key = "worldSettings." + id.uuidString
    }

    private var stored: [String: Any] { defaults.dictionary(forKey: key) ?? [:] }

    var lastDimension: String? { stored["dimension"] as? String }

    func hasShownVersionNotice(_ id: String) -> Bool {
        (stored["shownVersionNotices"] as? [String] ?? []).contains(id)
    }

    func recordVersionNotice(_ id: String) {
        var saved = stored
        var shown = Set(saved["shownVersionNotices"] as? [String] ?? [])
        guard shown.insert(id).inserted else { return }
        saved["shownVersionNotices"] = shown.sorted()
        defaults.set(saved, forKey: key)
    }

    /// The viewport is saved beside the choices, but remains independently owned by navigation.
    nonisolated private struct MapRecord: Codable {
        var viewport: MapViewport?
        var presentation: MapPresentation

        init(viewport: MapViewport?, presentation: MapPresentation) {
            self.viewport = viewport
            self.presentation = presentation
        }

        private enum CodingKeys: String, CodingKey { case viewport, presentation }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            presentation = (try? values.decode(MapPresentation.self, forKey: .presentation)) ?? MapPresentation()
            viewport = Self.viewport(from: try? values.decode([Double].self, forKey: .viewport))
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(presentation, forKey: .presentation)
            if let viewport {
                try values.encode([viewport.center.x, viewport.center.y, viewport.scale], forKey: .viewport)
            }
        }

        static func viewport(from view: [Double]?) -> MapViewport? {
            guard let view, view.count == 3, view[2].isFinite, view[2] > 0 else { return nil }
            let viewport = MapViewport(center: CGPoint(x: view[0], y: view[1]), scale: view[2])
            return viewport.isValid ? viewport : nil
        }
    }

    func viewport(for dimension: String) -> MapViewport? { record(for: dimension).viewport }

    func mapPresentation(for dimension: String?) -> MapPresentation { record(for: dimension).presentation }

    /// A choice changes immediately, even with no visible SwiftUI view or usable terrain reader.
    /// Keep the saved viewport and front dimension until their own owners change them.
    func save(_ presentation: MapPresentation, for dimension: String?) {
        guard let dimension else { return }
        var record = record(for: dimension)
        record.presentation = presentation
        write(record, for: dimension, in: stored)
    }

    func save(_ viewport: MapViewport, presentation: MapPresentation, for dimension: String, selected: String?) {
        guard viewport.isValid else { return }
        var saved = stored
        saved["dimension"] = selected
        write(MapRecord(viewport: viewport, presentation: presentation), for: dimension, in: saved)
    }

    private func record(for dimension: String?) -> MapRecord {
        if let dimension, let data = (stored["mapPresentations"] as? [String: Any])?[dimension] as? Data,
           let record = try? JSONDecoder().decode(MapRecord.self, from: data) {
            return record
        }
        return MapRecord(viewport: nil, presentation: MapPresentation())
    }

    private func write(_ record: MapRecord, for dimension: String, in previous: [String: Any]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(record) else { return }
        var saved = previous
        var records = saved["mapPresentations"] as? [String: Any] ?? [:]
        records[dimension] = data
        saved["mapPresentations"] = records
        defaults.set(saved, forKey: key)
    }

    var savedPlaces: [SavedPlace] {
        (stored["places"] as? Data).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
    }

    func savePlaces(_ places: [SavedPlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        var saved = stored
        saved["places"] = data
        defaults.set(saved, forKey: key)
    }
}
