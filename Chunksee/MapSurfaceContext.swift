import ChunkseeKit

/// The dimension's published definition inputs, separate from its window's map choices.
nonisolated struct MapDefinitions: Equatable, Sendable {
    static let unknown = MapDefinitions(context: .unknown, heightScale: nil)
    let context: MapSurfaceContext
    let heightScale: MapHeightScale?

    init(context: MapSurfaceContext, heightScale: MapHeightScale?) {
        self.context = context
        self.heightScale = heightScale
    }

    init(settings: DimensionSettings?, water: GameTag?) {
        context = MapSurfaceContext(settings: settings, water: water)
        heightScale = MapHeightScale(settings: settings)
    }
}

/// Display choices derived once from the reader's saved dimension facts. They describe the
/// normal map view; an explicit cutaway height takes precedence over this ceiling view.
nonisolated struct MapSurfaceContext: Equatable, Sendable {
    static let unknown = MapSurfaceContext(settings: nil, water: nil)

    let dimensionType: DimensionType?
    let buildHeight: Int?
    let ceilingY: Int?
    let biomeSampleY: Int?
    let water: GameTag?
    let waterKey: [String]?

    init(settings: DimensionSettings?, water: GameTag?) {
        self.water = water
        waterKey = water.map { $0.members.map(\.id).sorted() }
        dimensionType = settings?.type
        buildHeight = settings?.type?.height
        if let type = settings?.type, !type.hasCeiling {
            ceilingY = nil
            biomeSampleY = nil
            return
        }
        if let type = settings?.type, let range = settings?.noiseGeneration?.surfaceRuleRange(in: type) {
            // The saved context supplies a starting plane, not a verified roof block. An
            // explicitly empty range is known too, and supplies no ceiling plane.
            ceilingY = range.isEmpty ? nil : range.upperBound - 1
            biomeSampleY = range.isEmpty ? nil : range.lowerBound + range.count / 2
            return
        }
        // Without a resolved type/generator there is no known ceiling plane.
        ceilingY = nil
        biomeSampleY = nil
    }
}
