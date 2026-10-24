/// Presentation-only lighting for the cached surface. Water and diagnostic height colours bypass it.
nonisolated struct MapRelief {
    private let bounds: ClosedRange<Int>?
    private let elevation: [Double]

    init(heightScale: MapHeightScale?) {
        // Without a saved sea level there is no justified midpoint for an elevation tint.
        guard let heightScale, heightScale.seaLevel != nil else {
            bounds = nil
            elevation = []
            return
        }
        bounds = heightScale.bounds
        // Many columns share a height. Resolve the shared scale once per build height, not per pixel.
        elevation = heightScale.bounds.map { y in
            let distance = 2 * heightScale.level(at: y) - 1
            return 1 - 0.08 * distance * distance
        }
    }

    /// The normal tile and its close-up pixels use the same slope at each selected column.
    /// Top/left differences extrapolate from the next row/column at the region edge.
    func factor(at index: Int, heights: [Int32], side: Int) -> Double {
        let x = index % side, z = index / side, height = heights[index]
        let north = heights[z > 0 ? index - side : index + side]
        let west = heights[x > 0 ? index - 1 : index + 1]
        let northDifference = north == RegionTileRenderer.Canvas.noHeight ? 0
            : (Int64(height) - Int64(north)) * (z > 0 ? 1 : -1)
        let westDifference = west == RegionTileRenderer.Canvas.noHeight ? 0
            : (Int64(height) - Int64(west)) * (x > 0 ? 1 : -1)
        return factor(height: height, north: northDifference, west: westDifference)
    }

    /// North-west light: shallow slopes have less contrast than cliffs, with bounded extremes.
    func factor(height: Int32, north: Int64, west: Int64) -> Double {
        let slope = min(1.2, max(0.75, 1 + 0.025 * Double(north + west)))
        guard let bounds else { return slope }
        let y = min(bounds.upperBound, max(bounds.lowerBound, Int(height)))
        return slope * elevation[y - bounds.lowerBound]
    }
}
