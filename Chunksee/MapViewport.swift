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

    /// Fit World can go below the smallest 1/16× preset for widely separated terrain. The most is 32×
    /// (3,200%): each block's one-pixel tile color is drawn unsmoothed, so closer zoom adds no detail.
    static let scaleRange: ClosedRange<CGFloat> = 0.00000001 ... 32
    static let minimumManualScale: CGFloat = 1.0 / 16
    var canZoomOut: Bool { scale > Self.minimumManualScale }
    var isValid: Bool {
        Coordinates.block(center.x) != nil && Coordinates.block(center.y) != nil &&
            scale.isFinite && Self.scaleRange.contains(scale)
    }

    init(center: CGPoint = .zero, scale: CGFloat = 1) {
        self.center = center
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    /// The world block position under a point in a view of `size`.
    func blockPoint(at viewPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: center.x + (viewPoint.x - size.width / 2) / scale,
                y: center.y + (viewPoint.y - size.height / 2) / scale)
    }

    /// The view point of a world block position (the inverse of `blockPoint(at:in:)`).
    func viewPoint(for block: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (block.x - center.x) * scale + size.width / 2,
                y: (block.y - center.y) * scale + size.height / 2)
    }

    /// Where a region's tile is drawn in a view of `size`.
    func viewRect(for region: RegionCoordinate, in size: CGSize) -> CGRect {
        let side = CGFloat(RegionCoordinate.blockSize)
        return CGRect(x: (CGFloat(region.x) * side - center.x) * scale + size.width / 2,
                      y: (CGFloat(region.z) * side - center.y) * scale + size.height / 2,
                      width: side * scale, height: side * scale)
    }

    /// The block of region coordinates that intersects the view.
    struct RegionRange: Equatable, Sendable {
        var xs: ClosedRange<Int>
        var zs: ClosedRange<Int>
    }

    func visibleRegionRange(in size: CGSize) -> RegionRange? {
        guard isValid, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return nil }
        let topLeft = blockPoint(at: .zero, in: size)
        let bottomRight = blockPoint(at: CGPoint(x: size.width, y: size.height), in: size)
        let side = Double(RegionCoordinate.blockSize)
        guard let minX = Coordinates.block(topLeft.x / side), let maxX = Coordinates.block(bottomRight.x / side),
              let minZ = Coordinates.block(topLeft.y / side), let maxZ = Coordinates.block(bottomRight.y / side),
              minX <= maxX, minZ <= maxZ else { return nil }
        return RegionRange(xs: minX...maxX, zs: minZ...maxZ)
    }

    /// Enumerate only saved regions, so fitting distant terrain never walks the empty space.
    func visibleRegions(in size: CGSize, among available: Set<RegionCoordinate>) -> [RegionCoordinate] {
        guard let range = visibleRegionRange(in: size) else { return [] }
        return available.filter { range.xs.contains($0.x) && range.zs.contains($0.z) }
            .sorted { distanceToCenter($0) < distanceToCenter($1) }
    }

    /// Region headers locate all saved terrain without reading individual chunks.
    static func fitting(_ regions: Set<RegionCoordinate>, in size: CGSize, padding: CGFloat = 24) -> MapViewport? {
        guard !regions.isEmpty, size.width > padding * 2, size.height > padding * 2,
              let minX = regions.map(\.x).min(), let maxX = regions.map(\.x).max(),
              let minZ = regions.map(\.z).min(), let maxZ = regions.map(\.z).max() else { return nil }
        let side = CGFloat(RegionCoordinate.blockSize)
        let left = CGFloat(minX) * side, top = CGFloat(minZ) * side
        let width = (CGFloat(maxX) - CGFloat(minX) + 1) * side
        let height = (CGFloat(maxZ) - CGFloat(minZ) + 1) * side
        return MapViewport(center: CGPoint(x: left + width / 2, y: top + height / 2),
                           scale: min((size.width - padding * 2) / width, (size.height - padding * 2) / height))
    }

    func distanceToCenter(_ region: RegionCoordinate) -> CGFloat {
        let half = CGFloat(RegionCoordinate.blockSize) / 2
        return hypot(CGFloat(region.x) * CGFloat(RegionCoordinate.blockSize) + half - center.x,
                     CGFloat(region.z) * CGFloat(RegionCoordinate.blockSize) + half - center.y)
    }

    /// Moves the map with the pointer, so content follows a drag.
    mutating func pan(by viewDelta: CGSize) {
        center.x -= viewDelta.width / scale
        center.y -= viewDelta.height / scale
    }

    /// Manual zoom stops at 1/16×. Smaller fitted views can zoom in gradually, but not farther out.
    mutating func zoom(by factor: CGFloat) {
        scale = min(max(scale * factor, min(scale, Self.minimumManualScale)), Self.scaleRange.upperBound)
    }

    /// Zooms by `factor`, keeping the block under `anchor` in place.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint, in size: CGSize) {
        let fixed = blockPoint(at: anchor, in: size)
        let previousScale = scale
        zoom(by: factor)
        guard scale != previousScale else { return }
        center = CGPoint(x: fixed.x - (anchor.x - size.width / 2) / scale,
                         y: fixed.y - (anchor.y - size.height / 2) / scale)
    }
}
