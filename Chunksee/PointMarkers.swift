import ChunkseeIndex
import CoreGraphics

/// An immutable marker snapshot with its region buckets. Reused across viewport/visibility changes.
nonisolated struct PointMarkers<Marker: MapLayerMarker & Sendable>: Sendable {
    private let index: PointIndex<Marker>
    var all: [Marker] { index.elements }

    init(_ markers: [Marker] = []) {
        index = PointIndex(markers) { marker in
            (x: Double(marker.position.x), z: Double(marker.position.y))
        }
    }

    /// Broad bucket candidates, in original drawing/accessibility order. Each caller still applies
    /// its exact bounds or hit distance; the supplied view rectangle includes that path's margin.
    func candidates(in viewRect: CGRect, viewport: MapViewport, size: CGSize) -> [Marker] {
        guard !all.isEmpty else { return [] }
        guard viewport.scale.isFinite, viewport.scale > 0 else { return all }
        let start = viewport.blockPoint(at: viewRect.origin, in: size)
        let end = viewport.blockPoint(at: CGPoint(x: viewRect.maxX, y: viewRect.maxY), in: size)
        return index.candidates(minX: Double(start.x), maxX: Double(end.x),
                                minZ: Double(start.y), maxZ: Double(end.y))
    }
}
