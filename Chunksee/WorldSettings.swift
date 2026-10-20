import CoreGraphics
import Foundation

/// One world's persisted presentation, shared by its dimension documents. Feature models own
/// live state; this owner alone handles its storage, legacy import and native folder moves.
final class WorldSettings {
    enum Layer: String, CaseIterable {
        case structures = "shownStructureGroups", places = "shownPlaceGroups"
        case creatures = "shownCreatureGroups", biomes = "shownBiomeGroups"
        case hiddenPlayers, showsGrid, timeSpent = "showsTimeSpent", slimeChunks = "showsSlimeChunks"

        fileprivate static let legacy: [Layer] = [.structures, .places, .creatures, .biomes, .hiddenPlayers, .showsGrid]
    }

    private let defaults: UserDefaults
    private var key: String

    init(world: URL, defaults: UserDefaults) {
        self.defaults = defaults
        key = Self.key(for: world)
        guard defaults.dictionary(forKey: key) == nil else { return }
        let path = world.standardizedFileURL.path
        var imported = defaults.dictionary(forKey: "mapView." + path) ?? [:]
        imported["version"] = 1
        imported["layers"] = defaults.dictionary(forKey: "mapLayers." + path)
        imported["places"] = defaults.data(forKey: "savedPlaces." + path)
        defaults.set(imported, forKey: key)
        for prefix in ["mapView.", "mapLayers.", "savedPlaces."] { defaults.removeObject(forKey: prefix + path) }
    }

    private static func key(for world: URL) -> String { "worldSettings." + world.standardizedFileURL.path }
    private var stored: [String: Any] { defaults.dictionary(forKey: key) ?? ["version": 1] }

    var lastDimension: String? { stored["dimension"] as? String }

    func viewport(for dimension: String) -> MapViewport? {
        guard let view = (stored["views"] as? [String: [Double]])?[dimension], view.count == 3,
              view[2].isFinite, view[2] > 0 else { return nil }
        let viewport = MapViewport(center: CGPoint(x: view[0], y: view[1]), scale: view[2])
        return viewport.isValid ? viewport : nil
    }

    func depth(for dimension: String) -> MapDepth {
        guard let value = (stored["depths"] as? [String: [String: Int]])?[dimension],
              let y = value["y"], let surface = value["surface"], surface == 0 || surface == 1 else { return MapDepth() }
        return MapDepth(y: y, isSurface: surface == 1)
    }

    func save(_ viewport: MapViewport, for dimension: String, selected: String?, depth: MapDepth? = nil) {
        guard viewport.isValid else { return }
        var saved = stored
        var views = saved["views"] as? [String: [Double]] ?? [:]
        views[dimension] = [viewport.center.x, viewport.center.y, viewport.scale]
        saved["views"] = views
        if let depth {
            var depths = saved["depths"] as? [String: [String: Int]] ?? [:]
            depths[dimension] = ["y": depth.y, "surface": depth.isSurface ? 1 : 0]
            saved["depths"] = depths
        }
        saved["dimension"] = selected
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

    func layers(for dimension: String?) -> [Layer: Any]? {
        guard let dimension, let values = (stored["layers"] as? [String: [String: Any]])?[dimension] else { return nil }
        return Dictionary(uniqueKeysWithValues: Layer.allCases.compactMap { field in
            values[field.rawValue].map { (field, $0) }
        })
    }

    /// Old app-wide choices seed a dimension once; live controls never write those keys.
    var legacyLayers: [Layer: Any] {
        Dictionary(uniqueKeysWithValues: Layer.legacy.compactMap { field in
            defaults.object(forKey: field.rawValue).map { (field, $0) }
        })
    }

    func saveLayers(_ values: [Layer: Any], for dimension: String?) {
        guard let dimension else { return }
        var saved = stored
        var dimensions = saved["layers"] as? [String: [String: Any]] ?? [:]
        var layers = dimensions[dimension] ?? [:]
        for (field, value) in values { layers[field.rawValue] = value }
        dimensions[dimension] = layers
        saved["layers"] = dimensions
        defaults.set(saved, forKey: key)
    }

    /// Retain all dimensions and annotations. Sibling tabs still closing at the old URL share
    /// this owner, so their final saves follow the new key instead of recreating the old one.
    func relocate(to world: URL) {
        let destinationKey = Self.key(for: world)
        guard destinationKey != key else { return }
        let destination = WorldSettings(world: world, defaults: defaults)
        let moving = stored
        var merged = destination.stored
        for section in ["views", "depths", "layers"] {
            merged[section] = (merged[section] as? [String: Any] ?? [:]).merging(moving[section] as? [String: Any] ?? [:]) { _, current in current }
        }
        if let dimension = moving["dimension"] { merged["dimension"] = dimension }
        // Keep the destination's existing annotation for duplicate IDs, as before. Panning
        // never decodes or re-encodes this payload; only annotation edits and a move do.
        if merged["places"] == nil { merged["places"] = moving["places"] }
        else if moving["places"] != nil {
            let existing = destination.savedPlaces
            let ids = Set(existing.map(\.id))
            let places = existing + savedPlaces.filter { !ids.contains($0.id) }
            if let data = try? JSONEncoder().encode(places) { merged["places"] = data }
        }
        defaults.set(merged, forKey: destinationKey)
        defaults.removeObject(forKey: key)
        key = destinationKey
    }
}
