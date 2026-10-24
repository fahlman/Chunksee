import CoreGraphics
import Foundation

/// One world's persisted presentation, shared by its dimension documents. Feature models own
/// live state; its bookmark identity keeps this storage independent of the folder's path.
final class WorldSettings {
    enum Layer: String, CaseIterable {
        case structures = "shownStructureGroups", places = "shownPlaceGroups"
        case creatures = "shownCreatureGroups", biomes = "shownBiomeGroups"
        case hiddenPlayers, showsGrid, showsSavedPlaces, timeSpent = "showsTimeSpent", slimeChunks = "showsSlimeChunks"
        case showsWorldBorder

        fileprivate static let legacy: [Layer] = [.structures, .places, .creatures, .biomes, .hiddenPlayers, .showsGrid]
    }

    private let defaults: UserDefaults
    let worldID: UUID
    private let key: String

    convenience init(folder: WorldFolders.Folder, defaults: UserDefaults) {
        self.init(id: folder.id, defaults: defaults, legacyPaths: [folder.url.path, folder.legacyPath].compactMap { $0 })
    }

    init(id: UUID, defaults: UserDefaults, legacyPaths: [String] = []) {
        self.defaults = defaults
        worldID = id
        key = "worldSettings." + id.uuidString
        guard defaults.dictionary(forKey: key) == nil else { return }
        func legacy(_ path: String) -> [String: Any] {
            if let existing = defaults.dictionary(forKey: "worldSettings." + path) { return existing }
            var value = defaults.dictionary(forKey: "mapView." + path) ?? [:]
            value["layers"] = defaults.dictionary(forKey: "mapLayers." + path)
            value["places"] = defaults.data(forKey: "savedPlaces." + path)
            return value
        }
        var imported: [String: Any] = [:]
        var paths: Set<String> = []
        for path in legacyPaths where paths.insert(path).inserted {
            imported = Self.merging(legacy(path), into: imported)
        }
        imported["version"] = 1
        defaults.set(imported, forKey: key)
        for path in paths {
            for prefix in ["worldSettings.", "mapView.", "mapLayers.", "savedPlaces."] { defaults.removeObject(forKey: prefix + path) }
        }
    }

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

    func style(for dimension: String) -> MapStyle {
        let value = (stored["styles"] as? [String: String])?[dimension]
        return value.flatMap(MapStyle.init(rawValue:)) ?? .normal
    }

    func lightingMode(for dimension: String) -> MapLightingMode {
        let value = (stored["lightingModes"] as? [String: String])?[dimension]
        return value.flatMap(MapLightingMode.init(rawValue:)) ?? .savedTime
    }

    func blockFilter(for dimension: String) -> MapBlockFilter {
        guard let value = (stored["blockFilters"] as? [String: [String: Any]])?[dimension] else { return MapBlockFilter() }
        return MapBlockFilter(isEnabled: value["enabled"] as? Bool ?? true,
                              hiddenIDs: Set(value["hidden"] as? [String] ?? []),
                              highlightedIDs: Set(value["highlighted"] as? [String] ?? []))
    }

    func save(_ viewport: MapViewport, for dimension: String, selected: String?, depth: MapDepth? = nil,
              style: MapStyle? = nil, blockFilter: MapBlockFilter? = nil, lightingMode: MapLightingMode? = nil) {
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
        if let style {
            var styles = saved["styles"] as? [String: String] ?? [:]
            styles[dimension] = style.rawValue
            saved["styles"] = styles
        }
        if let lightingMode {
            var modes = saved["lightingModes"] as? [String: String] ?? [:]
            modes[dimension] = lightingMode.rawValue
            saved["lightingModes"] = modes
        }
        if let blockFilter {
            var filters = saved["blockFilters"] as? [String: [String: Any]] ?? [:]
            filters[dimension] = ["enabled": blockFilter.isEnabled,
                                  "hidden": blockFilter.hiddenIDs.sorted(), "highlighted": blockFilter.highlightedIDs.sorted()]
            saved["blockFilters"] = filters
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

    /// A pre-migration move may have records at both paths. Keep the previous view choices and
    /// the destination's existing annotation for duplicate IDs, matching the old move policy.
    private static func merging(_ moving: [String: Any], into destination: [String: Any]) -> [String: Any] {
        var merged = destination
        for section in ["views", "depths", "layers"] {
            merged[section] = (merged[section] as? [String: Any] ?? [:]).merging(moving[section] as? [String: Any] ?? [:]) { _, current in current }
        }
        if let dimension = moving["dimension"] { merged["dimension"] = dimension }
        // A sole opaque payload survives migration unchanged. Panning never decodes it.
        if merged["places"] == nil { merged["places"] = moving["places"] }
        else if moving["places"] != nil {
            let existing = (destination["places"] as? Data).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
            let savedPlaces = (moving["places"] as? Data).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
            let ids = Set(existing.map(\.id))
            let places = existing + savedPlaces.filter { !ids.contains($0.id) }
            if let data = try? JSONEncoder().encode(places) { merged["places"] = data }
        }
        return merged
    }
}
