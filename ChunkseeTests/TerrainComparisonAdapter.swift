import SwiftUI
@testable import ChunkseeTestHost

/// Endpoint differences are confined to the entry signature and derived geometry evidence.
/// The geometry record never feeds drawing or its correctness decision.
@MainActor
enum TerrainComparisonAdapter {
    static let endpoint = "candidate"
    static let productHead = "bdac4391af2baf72c51b6eba214ee8ebf15aadf2"

    static func terrainRectangle(_ bounds: CGRect, scale: CGFloat) -> CGRect {
        scale < 1 ? bounds.insetBy(dx: -0.5, dy: -0.5) : bounds
    }

    static func draw(_ session: WorldSession, map: MapModel, content: MapContent,
                     context: GraphicsContext, size: CGSize) {
        MapView.drawMap(map, content: content, portalStatus: { session.presentation.linkStatus(for: $0) },
                        in: context, size: size)
    }
}
