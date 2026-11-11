import Foundation

extension GameNames {
    nonisolated func block(_ id: String) -> String { name(id, in: "block") }

    /// Names affect matching and order, never which saved IDs belong in the catalog.
    nonisolated func blockIDs(in catalog: Set<String>, matching query: String) -> [String] {
        catalog.map { (id: $0, name: block($0)) }
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            .map { $0.id }
    }

    /// The renderer counts water only to its limit; retain that distinction in the readout.
    nonisolated func blockDescription(_ surface: RegionTileRenderer.TopBlock, locale: Locale = .current) -> String {
        let name = block(surface.id)
        guard surface.waterDepth > 0 else { return name }
        return surface.waterDepth >= RegionTileRenderer.maximumWaterDepth
            ? String(localized: "\(name), at least \(surface.waterDepth) deep", locale: locale)
            : String(localized: "\(name), \(surface.waterDepth) deep", locale: locale)
    }
}
