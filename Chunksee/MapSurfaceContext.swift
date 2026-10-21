import ChunkseeKit

/// Display choices derived once from the reader's saved dimension facts. They describe the
/// normal map view; an explicit cutaway height takes precedence over this ceiling view.
nonisolated struct MapSurfaceContext: Equatable, Sendable {
    static let unknown = MapSurfaceContext(settings: nil)

    let buildHeight: Int?
    let ceilingY: Int?
    let biomeSampleY: Int?

    init(settings: DimensionSettings?) {
        buildHeight = settings?.type?.height
        guard let type = settings?.type, type.hasCeiling,
              let range = settings?.noiseGeneration?.surfaceRuleRange(in: type), !range.isEmpty else {
            ceilingY = nil
            biomeSampleY = nil
            return
        }
        // The generation context supplies the starting plane, not a claim that a roof block
        // exists there. The renderer still searches through actual saved blocks below it.
        ceilingY = range.upperBound - 1
        biomeSampleY = range.lowerBound + range.count / 2
    }
}
