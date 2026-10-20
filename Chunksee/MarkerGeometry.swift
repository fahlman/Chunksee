import CoreGraphics

/// Badge bodies shared by drawing, pointer targets and accessibility. Keep overview badges
/// legible, then let them fill one block at close zoom without exceeding 32 screen points.
nonisolated enum MarkerGeometry: Sendable {
    case structure, place(isPortal: Bool), creature(selected: Bool), search(selected: Bool)
    case player(MapMarker.Kind), savedPlace

    private var minimumRadius: CGFloat {
        switch self {
        case .structure: 9
        case .place(let isPortal): isPortal ? 8 : 6
        case .creature(let selected): selected ? 9 : 6
        case .search(let selected): selected ? 10 : 7
        case .player(let kind): kind == .player ? 11 : 9
        case .savedPlace: 8
        }
    }

    func radius(at scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return minimumRadius }
        return max(minimumRadius, min(scale, 32) / 2)
    }

    /// The same body rectangle positions Canvas drawing and its accessibility child.
    func frame(at point: CGPoint, scale: CGFloat) -> CGRect {
        let radius = radius(at: scale)
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Preserve the six-point tolerance already used for places/portals, consistently across
    /// badge sizes and selection. A larger selected body therefore has a larger target too.
    func hitRadius(at scale: CGFloat) -> CGFloat { radius(at: scale) + 6 }

    func symbolSide(at scale: CGFloat) -> CGFloat {
        let radius = radius(at: scale)
        return switch self {
        case .structure: radius * 4 / 3
        case .search: radius * 1.1
        case .player: radius * 1.15
        default: radius * 1.2
        }
    }
}
