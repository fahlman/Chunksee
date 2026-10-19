import CoreGraphics

/// Fixed badge bodies shared by drawing and pointer targets. Labels, structure outlines and
/// portal status decorations do not enlarge the body; zoom growth is a separate policy.
nonisolated enum MarkerGeometry: Sendable {
    case structure, place(isPortal: Bool), creature(selected: Bool), search(selected: Bool)
    case player(MapMarker.Kind), savedPlace

    var radius: CGFloat {
        switch self {
        case .structure: 9
        case .place(let isPortal): isPortal ? 8 : 6
        case .creature(let selected): selected ? 9 : 6
        case .search(let selected): selected ? 10 : 7
        case .player(let kind): kind == .player ? 11 : 9
        case .savedPlace: 8
        }
    }

    /// The same body rectangle positions Canvas drawing and its accessibility child.
    func frame(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Preserve the six-point tolerance already used for places/portals, consistently across
    /// badge sizes and selection. A larger selected body therefore has a larger target too.
    var hitRadius: CGFloat { radius + 6 }

    var symbolSide: CGFloat {
        switch self {
        case .structure: 12
        case .search: radius * 1.1
        case .player: radius * 1.15
        default: radius * 1.2
        }
    }
}
