import CoreGraphics

/// Block, chunk and region lines over the map, with coordinates along the top and left edges.
/// Block lines appear from 8 points apart, chunk lines from 12, and labels from 48.
nonisolated struct MapGrid: Equatable {
    struct Line: Equatable {
        /// World X (for a vertical line) or Z (for a horizontal one), in blocks.
        var block: Int
        /// Position in the view, in points.
        var position: CGFloat
        var isChunkEdge: Bool { block.isMultiple(of: MapGrid.chunk) }
        var isRegionEdge: Bool { block.isMultiple(of: MapGrid.region) }
    }

    var vertical: [Line] = []
    var horizontal: [Line] = []
    /// Whether the edges' coordinates are labeled; when chunk lines are too dense to label, only
    /// region lines are.
    var labelsChunks = false
    var labelsRegions = false

    static let chunk = 16
    static let region = 512
    static let minimumBlockSpacing: CGFloat = 8
    static let minimumLineSpacing: CGFloat = 12
    static let minimumLabelSpacing: CGFloat = 48

    init(viewport: MapViewport, size: CGSize) {
        let chunkSpacing = CGFloat(Self.chunk) * viewport.scale
        let regionSpacing = CGFloat(Self.region) * viewport.scale
        let step: Int
        if viewport.scale >= Self.minimumBlockSpacing {
            step = 1
        } else {
            step = chunkSpacing >= Self.minimumLineSpacing ? Self.chunk : Self.region
        }
        labelsChunks = chunkSpacing >= Self.minimumLabelSpacing
        labelsRegions = regionSpacing >= Self.minimumLabelSpacing
        let topLeft = viewport.blockPoint(at: .zero, in: size)
        let bottomRight = viewport.blockPoint(at: CGPoint(x: size.width, y: size.height), in: size)
        func lines(from start: CGFloat, to end: CGFloat, position: (Int) -> CGFloat) -> [Line] {
            let first = Int((start / CGFloat(step)).rounded(.up)) * step
            return stride(from: first, through: Int(end.rounded(.down)), by: step).map {
                Line(block: $0, position: position($0))
            }
        }
        vertical = lines(from: topLeft.x, to: bottomRight.x) { viewport.viewPoint(for: CGPoint(x: $0, y: 0), in: size).x }
        horizontal = lines(from: topLeft.y, to: bottomRight.y) { viewport.viewPoint(for: CGPoint(x: 0, y: $0), in: size).y }
    }

    func isLabeled(_ line: Line) -> Bool {
        line.isRegionEdge ? labelsRegions : line.isChunkEdge && labelsChunks
    }
}
