import CoreGraphics

/// A region file's coordinates. Each region covers 512×512 blocks.
nonisolated struct RegionCoordinate: Hashable, Sendable {
    var x: Int
    var z: Int

    static let blockSize = 512
}

/// Maps between view points and world block coordinates for the top-down map.
nonisolated struct MapViewport: Equatable, Sendable {
    /// The world block X/Z shown at the center of the view.
    var center: CGPoint
    /// View points per block.
    var scale: CGFloat

    /// From 1/16 point per block (a whole region in 32 points) to 16 points per block.
    static let scaleRange: ClosedRange<CGFloat> = 1.0 / 16 ... 16

    init(center: CGPoint = .zero, scale: CGFloat = 1) {
        self.center = center
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    /// The world block position under a point in a view of `size`.
    func blockPoint(at viewPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: center.x + (viewPoint.x - size.width / 2) / scale,
                y: center.y + (viewPoint.y - size.height / 2) / scale)
    }

    /// Where a region's tile is drawn in a view of `size`.
    func viewRect(for region: RegionCoordinate, in size: CGSize) -> CGRect {
        let side = CGFloat(RegionCoordinate.blockSize)
        return CGRect(x: (CGFloat(region.x) * side - center.x) * scale + size.width / 2,
                      y: (CGFloat(region.z) * side - center.y) * scale + size.height / 2,
                      width: side * scale, height: side * scale)
    }

    /// Regions that intersect the view, nearest to the center first so they load first.
    func visibleRegions(in size: CGSize) -> [RegionCoordinate] {
        let topLeft = blockPoint(at: .zero, in: size)
        let bottomRight = blockPoint(at: CGPoint(x: size.width, y: size.height), in: size)
        let side = Double(RegionCoordinate.blockSize)
        let xs = Int((topLeft.x / side).rounded(.down))...Int((bottomRight.x / side).rounded(.down))
        let zs = Int((topLeft.y / side).rounded(.down))...Int((bottomRight.y / side).rounded(.down))
        let regions = xs.flatMap { x in zs.map { z in RegionCoordinate(x: x, z: z) } }
        return regions.sorted { distanceToCenter($0) < distanceToCenter($1) }
    }

    func distanceToCenter(_ region: RegionCoordinate) -> CGFloat {
        let half = CGFloat(RegionCoordinate.blockSize) / 2
        return hypot(CGFloat(region.x * RegionCoordinate.blockSize) + half - center.x,
                     CGFloat(region.z * RegionCoordinate.blockSize) + half - center.y)
    }

    /// Moves the map with the pointer, so content follows a drag.
    mutating func pan(by viewDelta: CGSize) {
        center.x -= viewDelta.width / scale
        center.y -= viewDelta.height / scale
    }

    /// Zooms by `factor`, keeping the block under `anchor` in place.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint, in size: CGSize) {
        let fixed = blockPoint(at: anchor, in: size)
        scale = min(max(scale * factor, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        center = CGPoint(x: fixed.x - (anchor.x - size.width / 2) / scale,
                         y: fixed.y - (anchor.y - size.height / 2) / scale)
    }
}
