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
        guard viewport.isValid, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return }
        let chunkSpacing = CGFloat(Self.chunk) * viewport.scale
        let regionSpacing = CGFloat(Self.region) * viewport.scale
        var step: Int
        if viewport.scale >= Self.minimumBlockSpacing {
            step = 1
        } else {
            step = chunkSpacing >= Self.minimumLineSpacing ? Self.chunk : Self.region
            while CGFloat(step) * viewport.scale < Self.minimumLineSpacing {
                let next = step.multipliedReportingOverflow(by: 2)
                guard !next.overflow else { return }
                step = next.partialValue
            }
        }
        labelsChunks = chunkSpacing >= Self.minimumLabelSpacing
        labelsRegions = regionSpacing >= Self.minimumLabelSpacing
        let topLeft = viewport.blockPoint(at: .zero, in: size)
        let bottomRight = viewport.blockPoint(at: CGPoint(x: size.width, y: size.height), in: size)
        func lines(from start: CGFloat, to end: CGFloat, position: (Int) -> CGFloat) -> [Line] {
            guard let multiple = Int(exactly: (start / CGFloat(step)).rounded(.up)),
                  let last = Coordinates.block(end) else { return [] }
            let first = multiple.multipliedReportingOverflow(by: step)
            guard !first.overflow else { return [] }
            var block = first.partialValue, result: [Line] = []
            while block <= last {
                result.append(Line(block: block, position: position(block)))
                let next = block.addingReportingOverflow(step)
                if next.overflow { break }
                block = next.partialValue
            }
            return result
        }
        vertical = lines(from: topLeft.x, to: bottomRight.x) { viewport.viewPoint(for: CGPoint(x: $0, y: 0), in: size).x }
        horizontal = lines(from: topLeft.y, to: bottomRight.y) { viewport.viewPoint(for: CGPoint(x: 0, y: $0), in: size).y }
    }

    func isLabeled(_ line: Line) -> Bool {
        line.isRegionEdge ? labelsRegions : line.isChunkEdge && labelsChunks
    }
}
