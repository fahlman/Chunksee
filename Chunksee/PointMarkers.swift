import ChunkseeKit
import CoreGraphics
import Foundation

/// An immutable marker snapshot with its region buckets. Reused across viewport/visibility changes.
nonisolated struct PointMarkers<Marker: MapLayerMarker & Sendable>: Sendable {
    let all: [Marker]
    private let buckets: [RegionPosition: [Int]]
    /// Unusual edited positions outside the integer bucket range retain the old final checks.
    private let unbucketed: [Int]

    init(_ markers: [Marker] = []) {
        all = markers
        var buckets: [RegionPosition: [Int]] = [:], unbucketed: [Int] = []
        for (index, marker) in markers.enumerated() {
            if let x = Self.coordinate(marker.position.x), let z = Self.coordinate(marker.position.y) {
                buckets[RegionPosition(x: x, z: z), default: []].append(index)
            } else { unbucketed.append(index) }
        }
        self.buckets = buckets
        self.unbucketed = unbucketed
    }

    /// Broad bucket candidates, in original drawing/accessibility order. Each caller still applies
    /// its exact bounds or hit distance; the supplied view rectangle includes that path's margin.
    func candidates(in viewRect: CGRect, viewport: MapViewport, size: CGSize) -> [Marker] {
        guard !all.isEmpty else { return [] }
        let start = viewport.blockPoint(at: viewRect.origin, in: size)
        let end = viewport.blockPoint(at: CGPoint(x: viewRect.maxX, y: viewRect.maxY), in: size)
        guard viewport.scale.isFinite, viewport.scale > 0,
              let minX = Self.coordinate(start.x), let maxX = Self.coordinate(end.x),
              let minZ = Self.coordinate(start.y), let maxZ = Self.coordinate(end.y), minX <= maxX, minZ <= maxZ else { return all }
        var indices = unbucketed
        // At Fit World, the view can span enormous empty space. Visit occupied buckets instead of
        // enumerating that space; small views use direct lookups without scanning all bucket keys.
        let cells = (Double(maxX) - Double(minX) + 1) * (Double(maxZ) - Double(minZ) + 1)
        if cells <= Double(buckets.count) {
            for x in minX...maxX { for z in minZ...maxZ {
                indices += buckets[RegionPosition(x: x, z: z)] ?? []
            } }
        } else {
            for (region, members) in buckets where (minX...maxX).contains(region.x) && (minZ...maxZ).contains(region.z) {
                indices += members
            }
        }
        return indices.sorted().map { all[$0] }
    }

    private static func coordinate(_ value: CGFloat) -> Int? {
        Coordinates.block(value / MapViewport.regionSideInBlocks)
    }
}
