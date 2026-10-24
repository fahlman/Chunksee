import ChunkseeKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension MapImage {
    /// Streams one production tile at a time into one size-checked destination. The window's
    /// tile cache and viewport are untouched; cancellation discards the unpublished destination.
    @MainActor
    static func export(plan: MapExportPlan, regions: Set<RegionPosition>, renderer: RegionTileRenderer,
                       content: MapContent, portalStatus: @escaping (NetherPortal) -> PortalLinkStatus?,
                       colorScheme: ColorScheme, locale: Locale, contrast: ColorSchemeContrast = .standard,
                       progress: (Int, Int) -> Void,
                       readTile: @Sendable (RegionTileRenderer, RegionPosition) async throws -> RegionTileRenderer.RenderedTile?
                           = { try await $0.tile(for: $1) }) async throws -> MapImage {
        try Task.checkCancellation()
        guard let destination = imageContext(width: plan.width, height: plan.height) else {
            throw ExportFailure.cannotRender
        }
        let visible = plan.viewport.visibleRegions(in: plan.size, among: regions)
        progress(0, visible.count)
        for (index, region) in visible.enumerated() {
            try Task.checkCancellation()
            if let tile = try await readTile(renderer, region) {
                try Task.checkCancellation()
                let image = plan.viewport.scale * CGFloat(RegionTileRenderer.side) > CGFloat(RegionTileRenderer.previewSide)
                    ? tile.full : tile.preview
                guard drawTerrainLayer(image, region: region, viewport: plan.viewport, size: plan.size, scale: 1,
                                       lighting: content.lighting, protectsWater: content.mapStyle == .waterDepth,
                                       contrast: contrast, into: destination) else { throw ExportFailure.cannotRender }
                if let write = tile.cacheWrite { await write.store() }
            }
            try Task.checkCancellation()
            progress(index + 1, visible.count)
        }
        let overlays = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            MapView.drawOverlays(viewport: plan.viewport, regions: visible, content: content,
                                 portalStatus: portalStatus, in: context, size: size)
        }
        .modifier(MapLegendOverlay(layers: content))
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, locale)
        guard drawImageLayer(overlays, size: plan.size, scale: 1, into: destination) else { throw ExportFailure.cannotRender }
        try Task.checkCancellation()
        guard let image = destination.makeImage() else { throw ExportFailure.cannotRender }
        return try await encodeExport(image)
    }

    /// The completed CGImage is immutable and transferred to this encoder; no drawing resumes on it.
    @concurrent
    private static func encodeExport(_ image: sending CGImage) async throws -> MapImage {
        try Task.checkCancellation()
        guard let image = png(image) else { throw ExportFailure.cannotRender }
        try Task.checkCancellation()
        return image
    }

    nonisolated enum ExportFailure: LocalizedError {
        case cannotRender

        var errorDescription: String? { String(localized: "The map image could not be created. Try a smaller area or scale.") }
    }
}
