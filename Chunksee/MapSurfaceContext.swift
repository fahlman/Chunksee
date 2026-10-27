import ChunkseeKit

/// Display choices derived once from the reader's saved dimension facts. They describe the
/// normal map view; an explicit cutaway height takes precedence over this ceiling view.
nonisolated struct MapSurfaceContext: Equatable, Sendable {
    static let unknown = MapSurfaceContext(settings: nil)

    let dimensionType: DimensionType?
    let buildHeight: Int?
    let ceilingY: Int?
    let biomeSampleY: Int?
    let water: GameTag?

    init(settings: DimensionSettings?, water: GameTag? = nil) {
        self.water = water
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

    var waterKey: String? {
        water.map { CacheKey.hash($0.members.map(\.id).sorted().joined(separator: "\n")) }
    }
}
