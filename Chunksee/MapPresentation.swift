import ChunkseeIndex
import ChunkseeKit
import Foundation

/// The user's choices for one dimension. Availability changes the drawing, never these choices.
nonisolated struct MapPresentation: Equatable, Sendable, Codable {
    var style = MapStyle.normal
    var depth = MapDepth()
    var blockFilter = MapBlockFilter()
    var lightingMode = MapLightingMode.savedTime
    var castsShadows = true
    var blendsBiomeColors = false
    var overlays = LayerVisibility()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case style, depth, blockFilter, lightingMode, castsShadows, blendsBiomeColors, overlays
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A missing or unfamiliar choice must not discard its readable siblings.
        if let value = try? values.decode(MapStyle.self, forKey: .style) { style = value }
        if let value = try? values.decode(MapDepth.self, forKey: .depth) { depth = value }
        if let value = try? values.decode(MapBlockFilter.self, forKey: .blockFilter) { blockFilter = value }
        if let value = try? values.decode(MapLightingMode.self, forKey: .lightingMode) { lightingMode = value }
        if let value = try? values.decode(Bool.self, forKey: .castsShadows) { castsShadows = value }
        if let value = try? values.decode(Bool.self, forKey: .blendsBiomeColors) { blendsBiomeColors = value }
        if let value = try? values.decode(LayerVisibility.self, forKey: .overlays) { overlays = value }
    }
}

/// Overlay choices are part of MapModel's presentation; they have no separate store or lifetime.
nonisolated struct LayerVisibility: Equatable, Sendable, Codable {
    var structures = Set(StructureGroup.allCases.filter(\.isShownByDefault))
    var places = Set(PlaceGroup.allCases.filter(\.isShownByDefault))
    var creatures = Set(CreatureGroup.allCases.filter(\.isShownByDefault))
    var mobTypes: Set<String> = []
    /// Appearance filters last only for the open dimension and are deliberately not encoded.
    var mobAppearances: [String: MobAppearance] = [:]
    var biomes: Set<BiomeGroup> = []
    var hiddenPlayers: Set<UUID> = []
    var showsGrid = false
    var showsSavedPlaces = true
    var showsWorldBorder = true
    var showsTimeSpent = false
    var showsSlimeChunks = false
    var showsDarkSpots = false

    init() {}

    func appearance(for kind: MobTypes.Kind) -> MobAppearance? {
        guard let appearance = mobAppearances[kind.id], kind.contains(appearance) else { return nil }
        return appearance
    }

    mutating func reveal(_ selection: CreatureSelection) {
        switch selection.list {
        case .mobs(let id):
            mobTypes.insert(id)
            if let filter = mobAppearances[id], filter != MobAppearance(selection.marker.creature.appearance) {
                mobAppearances[id] = nil
            }
        case .creatures(let group):
            creatures.insert(group)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case structures, places, creatures, mobTypes, biomes, hiddenPlayers
        case showsGrid, showsSavedPlaces, showsWorldBorder, showsTimeSpent, showsSlimeChunks, showsDarkSpots
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let choices = try? values.decode([String: Bool].self, forKey: .structures) {
            structures = Set(StructureGroup.allCases.filter { choices[$0.rawValue] ?? $0.isShownByDefault })
        }
        if let names = try? values.decode([String].self, forKey: .places) {
            places = Set(names.compactMap(PlaceGroup.init(rawValue:)))
        }
        if let names = try? values.decode([String].self, forKey: .creatures) {
            creatures = Set(names.compactMap(CreatureGroup.init(rawValue:)))
        }
        if let names = try? values.decode([String].self, forKey: .mobTypes) { mobTypes = Set(names) }
        if let names = try? values.decode([String].self, forKey: .biomes) { biomes = Set(names.map(BiomeGroup.init(id:))) }
        if let names = try? values.decode([String].self, forKey: .hiddenPlayers) {
            hiddenPlayers = Set(names.compactMap(UUID.init(uuidString:)))
        }
        if let value = try? values.decode(Bool.self, forKey: .showsGrid) { showsGrid = value }
        if let value = try? values.decode(Bool.self, forKey: .showsSavedPlaces) { showsSavedPlaces = value }
        if let value = try? values.decode(Bool.self, forKey: .showsWorldBorder) { showsWorldBorder = value }
        if let value = try? values.decode(Bool.self, forKey: .showsTimeSpent) { showsTimeSpent = value }
        if let value = try? values.decode(Bool.self, forKey: .showsSlimeChunks) { showsSlimeChunks = value }
        if let value = try? values.decode(Bool.self, forKey: .showsDarkSpots) { showsDarkSpots = value }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Remember both shown and hidden groups so a newly added group can still use its default.
        try values.encode(Dictionary(uniqueKeysWithValues: StructureGroup.allCases.map {
            ($0.rawValue, structures.contains($0))
        }), forKey: .structures)
        try values.encode(places.map(\.rawValue).sorted(), forKey: .places)
        try values.encode(creatures.map(\.rawValue).sorted(), forKey: .creatures)
        try values.encode(mobTypes.sorted(), forKey: .mobTypes)
        try values.encode(biomes.map(\.id).sorted(), forKey: .biomes)
        try values.encode(hiddenPlayers.map(\.uuidString).sorted(), forKey: .hiddenPlayers)
        try values.encode(showsGrid, forKey: .showsGrid)
        try values.encode(showsSavedPlaces, forKey: .showsSavedPlaces)
        try values.encode(showsWorldBorder, forKey: .showsWorldBorder)
        try values.encode(showsTimeSpent, forKey: .showsTimeSpent)
        try values.encode(showsSlimeChunks, forKey: .showsSlimeChunks)
        try values.encode(showsDarkSpots, forKey: .showsDarkSpots)
    }
}
