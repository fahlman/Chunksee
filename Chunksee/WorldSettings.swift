import CoreGraphics
import Foundation
import ChunkseeIndex

/// One world's persisted presentation, shared by its dimension documents. Feature models own
/// live state; its bookmark identity keeps this storage independent of the folder's path.
final class WorldSettings {
    private enum Layer: String {
        case structures = "shownStructureGroups", places = "shownPlaceGroups"
        case structureVisibility
        case creatures = "shownCreatureGroups", biomes = "shownBiomeGroups"
        case mobTypes = "shownMobTypes"
        case hiddenPlayers, showsGrid, showsSavedPlaces, timeSpent = "showsTimeSpent", slimeChunks = "showsSlimeChunks"
        case showsWorldBorder, darkSpots = "showsDarkSpots"

        static let legacy: [Layer] = [.structures, .places, .creatures, .biomes, .hiddenPlayers, .showsGrid]
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

    private static let oldMapSections = ["views", "depths", "styles", "blockFilters", "biomeBlending",
                                         "lightingModes", "castsShadows", "layers"]

    private func record(for dimension: String?) -> MapRecord {
        let saved = stored
        if let dimension, let data = (saved["mapPresentations"] as? [String: Any])?[dimension] as? Data,
           let record = try? JSONDecoder().decode(MapRecord.self, from: data) { return record }
        let record = legacyRecord(for: dimension, in: saved)
        if let dimension { write(record, for: dimension, in: saved) }
        return record
    }

    private func write(_ record: MapRecord, for dimension: String, in previous: [String: Any]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(record) else { return }
        var saved = previous
        var records = saved["mapPresentations"] as? [String: Any] ?? [:]
        records[dimension] = data
        saved["mapPresentations"] = records
        // Retire only this dimension's old fields. Unopened dimensions migrate when first read.
        for section in Self.oldMapSections {
            guard var values = saved[section] as? [String: Any] else { continue }
            values[dimension] = nil
            saved[section] = values.isEmpty ? nil : values
        }
        saved["version"] = 2
        defaults.set(saved, forKey: key)
    }

    private func legacyRecord(for dimension: String?, in saved: [String: Any]) -> MapRecord {
        func field(_ section: String) -> Any? {
            dimension.flatMap { (saved[section] as? [String: Any])?[$0] }
        }
        var presentation = MapPresentation()
        if let value = field("depths") as? [String: Int], let y = value["y"],
           let surface = value["surface"], surface == 0 || surface == 1 {
            presentation.depth = MapDepth(y: y, isSurface: surface == 1)
        }
        if let raw = field("styles") as? String, let style = MapStyle(rawValue: raw) { presentation.style = style }
        if let value = field("biomeBlending") as? Bool { presentation.blendsBiomeColors = value }
        if let raw = field("lightingModes") as? String, let mode = MapLightingMode(rawValue: raw) { presentation.lightingMode = mode }
        if let value = field("castsShadows") as? Bool { presentation.castsShadows = value }
        if let value = field("blockFilters") as? [String: Any] {
            presentation.blockFilter = MapBlockFilter(isEnabled: value["enabled"] as? Bool ?? presentation.blockFilter.isEnabled,
                hiddenIDs: Set(value["hidden"] as? [String] ?? []), highlightedIDs: Set(value["highlighted"] as? [String] ?? []))
        }
        let values = (field("layers") as? [String: Any]) ?? Dictionary(uniqueKeysWithValues: Layer.legacy.compactMap { field in
            defaults.object(forKey: field.rawValue).map { (field.rawValue, $0) }
        })
        var overlays = presentation.overlays
        if let choices = values[Layer.structureVisibility.rawValue] as? [String: Bool] {
            overlays.structures = Set(StructureGroup.allCases.filter { choices[$0.rawValue] ?? $0.isShownByDefault })
        } else if let shown = values[Layer.structures.rawValue] as? [String] {
            // This is the fixed historical schema, not a catalog of current game content.
            let original: Set<StructureGroup> = [.village, .stronghold, .ancientCity, .trialChambers,
                .monument, .mansion, .temple, .ruins, .ruinedPortal, .shipwreck, .buriedTreasure,
                .outpost, .mineshaft, .fortress, .bastion, .netherFossil, .endCity, .other]
            overlays.structures = Set(shown.compactMap(StructureGroup.init(rawValue:)))
                .union(StructureGroup.allCases.filter { !original.contains($0) && $0.isShownByDefault })
        }
        if let names = values[Layer.places.rawValue] as? [String] { overlays.places = Set(names.compactMap(PlaceGroup.init(rawValue:))) }
        if let names = values[Layer.creatures.rawValue] as? [String] { overlays.creatures = Set(names.compactMap(CreatureGroup.init(rawValue:))) }
        if let names = values[Layer.mobTypes.rawValue] as? [String] { overlays.mobTypes = Set(names) }
        if let names = values[Layer.biomes.rawValue] as? [String] { overlays.biomes = Set(names.map(BiomeGroup.init(id:))) }
        if let names = values[Layer.hiddenPlayers.rawValue] as? [String] { overlays.hiddenPlayers = Set(names.compactMap(UUID.init(uuidString:))) }
        if let value = values[Layer.showsGrid.rawValue] as? Bool { overlays.showsGrid = value }
        if let value = values[Layer.showsSavedPlaces.rawValue] as? Bool { overlays.showsSavedPlaces = value }
        if let value = values[Layer.showsWorldBorder.rawValue] as? Bool { overlays.showsWorldBorder = value }
        if let value = values[Layer.timeSpent.rawValue] as? Bool { overlays.showsTimeSpent = value }
        if let value = values[Layer.slimeChunks.rawValue] as? Bool { overlays.showsSlimeChunks = value }
        if let value = values[Layer.darkSpots.rawValue] as? Bool { overlays.showsDarkSpots = value }
        presentation.overlays = overlays
        return MapRecord(viewport: MapRecord.viewport(from: field("views") as? [Double]), presentation: presentation)
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
