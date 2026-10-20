import CoreGraphics

/// Every point marker has the same body, glyph box and picking reach at a given zoom.
/// Keep an 18-point overview body, then grow with a block up to 32 screen points.
nonisolated enum MarkerGeometry {
    static func radius(at scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 9 }
        return max(9, min(scale, 32) / 2)
    }

    /// The same body rectangle positions Canvas drawing and its accessibility child.
    static func frame(at point: CGPoint, scale: CGFloat) -> CGRect {
        let radius = radius(at: scale)
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    /// The six-point tolerance stays outside the visible body, independent of selection.
    static func hitRadius(at scale: CGFloat) -> CGFloat { radius(at: scale) + 6 }

    static func symbolSide(at scale: CGFloat) -> CGFloat { radius(at: scale) * 4 / 3 }
}
