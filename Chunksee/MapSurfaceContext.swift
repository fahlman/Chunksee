import ChunkseeKit

/// Display choices derived once from the reader's saved dimension facts. They describe the
/// normal map view; an explicit cutaway height takes precedence over this ceiling view.
nonisolated struct MapSurfaceContext: Equatable, Sendable {
    static let unknown = MapSurfaceContext(dimensionID: nil, settings: nil)

    let buildHeight: Int?
    let ceilingY: Int?
    let biomeSampleY: Int?

    init(dimensionID: String?, settings: DimensionSettings?) {
        buildHeight = settings?.type?.height
        if let type = settings?.type, !type.hasCeiling {
            ceilingY = nil
            biomeSampleY = nil
            return
        }
        if let type = settings?.type, let range = settings?.noiseGeneration?.surfaceRuleRange(in: type) {
            // The saved context supplies a starting plane, not a verified roof block. An
            // explicitly empty range is known too, and must not acquire the fallback below.
            ceilingY = range.isEmpty ? nil : range.upperBound - 1
            biomeSampleY = range.isEmpty ? nil : range.lowerBound + range.count / 2
            return
        }
        // Keep the established Nether view when a version or data pack cannot be resolved.
        // This is a display fallback, not inferred build bounds or a new saved-format fact.
        let usesNetherFallback = dimensionID == "minecraft:the_nether"
        ceilingY = usesNetherFallback ? 127 : nil
        biomeSampleY = usesNetherFallback ? 64 : nil
    }
}
