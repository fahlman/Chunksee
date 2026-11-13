import SwiftUI
@testable import ChunkseeTestHost

/// Endpoint differences are confined to the entry signature and derived geometry evidence.
/// The geometry record never feeds drawing or its correctness decision.
@MainActor
enum TerrainComparisonAdapter {
    static let endpoint = "baseline"
    static let productHead = "d014540692923474f589e4d7b207050401ea636e"

    static func terrainRectangle(_ bounds: CGRect, scale: CGFloat) -> CGRect {
        bounds.insetBy(dx: -0.5, dy: -0.5)
    }

    static func draw(_ session: WorldSession, map: MapModel, content: MapContent,
                     context: GraphicsContext, size: CGSize) {
        MapView.drawMap(map, content: content, portalStatus: { session.presentation.linkStatus(for: $0) },
                        displayScale: context.environment.displayScale, in: context, size: size)
    }
}
