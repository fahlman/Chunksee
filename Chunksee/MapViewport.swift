import ChunkseeKit
import CoreGraphics

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
    /// Continuous map geometry needs a divisor; tested against Kit's checked region origin.
    /// This is measured in blocks, independently of a rendered tile's pixel resolution.
    static let regionSideInBlocks: CGFloat = 512
    var canZoomIn: Bool { scale < Self.scaleRange.upperBound }
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
        block.applying(transform(in: size))
    }

    /// The same world-to-view mapping for points, tiles and area paths.
    func transform(in size: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                          tx: size.width / 2 - center.x * scale,
                          ty: size.height / 2 - center.y * scale)
    }

    /// Where a region's tile is drawn in a view of `size`.
    func viewRect(for region: RegionPosition, in size: CGSize) -> CGRect? {
        guard let origin = region.blockOrigin else { return nil }
        let side = Self.regionSideInBlocks
        return CGRect(x: CGFloat(origin.x), y: CGFloat(origin.z), width: side, height: side)
            .applying(transform(in: size))
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
        let side = Self.regionSideInBlocks
        guard let minX = Coordinates.block(topLeft.x / side), let maxX = Coordinates.block(bottomRight.x / side),
              let minZ = Coordinates.block(topLeft.y / side), let maxZ = Coordinates.block(bottomRight.y / side),
              minX <= maxX, minZ <= maxZ else { return nil }
        return RegionRange(xs: minX...maxX, zs: minZ...maxZ)
    }

    /// Enumerate only saved regions, so fitting distant terrain never walks the empty space.
    func visibleRegions(in size: CGSize, among available: Set<RegionPosition>) -> [RegionPosition] {
        guard let range = visibleRegionRange(in: size) else { return [] }
        return available.filter { range.xs.contains($0.x) && range.zs.contains($0.z) && $0.blockOrigin != nil }
            .sorted { distanceToCenter($0) < distanceToCenter($1) }
    }

    /// Region headers locate all saved terrain without reading individual chunks.
    static func fitting(_ regions: Set<RegionPosition>, in size: CGSize, padding: CGFloat = 24) -> MapViewport? {
        guard size.width.isFinite, size.height.isFinite, size.width > padding * 2, size.height > padding * 2,
              let bounds = bounds(of: regions) else { return nil }
        return MapViewport(center: CGPoint(x: bounds.midX, y: bounds.midY),
                           scale: min((size.width - padding * 2) / bounds.width, (size.height - padding * 2) / bounds.height))
    }

    /// Shared extent for Fit World and whole-dimension images; empty space between saved regions stays empty.
    static func bounds(of regions: Set<RegionPosition>) -> CGRect? {
        let origins = regions.compactMap(\.blockOrigin)
        guard let minX = origins.map(\.x).min(), let maxX = origins.map(\.x).max(),
              let minZ = origins.map(\.z).min(), let maxZ = origins.map(\.z).max() else { return nil }
        let left = CGFloat(minX), top = CGFloat(minZ)
        let width = CGFloat(maxX) - left + Self.regionSideInBlocks
        let height = CGFloat(maxZ) - top + Self.regionSideInBlocks
        return CGRect(x: left, y: top, width: width, height: height)
    }

    func distanceToCenter(_ region: RegionPosition) -> CGFloat {
        guard let origin = region.blockOrigin else { return .greatestFiniteMagnitude }
        let half = Self.regionSideInBlocks / 2
        return hypot(CGFloat(origin.x) + half - center.x, CGFloat(origin.z) + half - center.y)
    }

    /// Moves the map with the pointer, so content follows a drag.
    mutating func pan(by viewDelta: CGSize) {
        center.x -= viewDelta.width / scale
        center.y -= viewDelta.height / scale
    }

    enum Direction { case north, south, west, east }

    /// Keyboard and accessibility commands move a quarter of the view along that axis.
    mutating func pan(_ direction: Direction, in size: CGSize) {
        let step = CGSize(width: size.width / 4, height: size.height / 4)
        let delta: CGSize
        switch direction {
        case .north: delta = CGSize(width: 0, height: step.height)
        case .south: delta = CGSize(width: 0, height: -step.height)
        case .west: delta = CGSize(width: step.width, height: 0)
        case .east: delta = CGSize(width: -step.width, height: 0)
        }
        pan(by: delta)
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
