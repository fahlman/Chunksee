import ChunkseeKit
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A PNG of the map as shown, to copy or share. The sandbox allows only read-only access to
/// files the user picks, so there's no save panel (Ryan's decision, fahlman/Chunksee#89).
nonisolated struct MapImage: Sendable {
    let data: Data

    /// Renders the map's current view, with the same overlays, at `scale` pixels per point.
    /// Only regions already drawn on screen appear, so it matches what the user sees.
    @MainActor
    static func render(_ map: MapModel, content: MapContent, portalStatus: @escaping (NetherPortal) -> PortalLinkStatus?,
                       size: CGSize, scale: CGFloat, colorScheme: ColorScheme, locale: Locale,
                       contrast: ColorSchemeContrast = .standard) -> MapImage? {
        guard scale.isFinite, scale > 0,
              let width = Int(exactly: (size.width * scale).rounded(.up)),
              let height = Int(exactly: (size.height * scale).rounded(.up)),
              let destination = imageContext(width: width, height: height) else { return nil }
        let visible = map.viewport.visibleRegions(in: size, among: map.availableRegions)
        let full = map.needsFullResolution(displayScale: scale)
        for region in visible {
            if let tile = map.image(for: region, fullResolution: full),
               !drawTerrainLayer(tile, region: region, viewport: map.viewport, size: size, scale: scale,
                                 lighting: map.lighting, protectsWater: map.style == .waterDepth,
                                 contrast: contrast, into: destination) { return nil }
        }
        if map.viewport.scale >= MapDetailRenderer.minimumScale {
            for chunk in map.detailImages.keys.sorted(by: { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }) {
                guard let image = map.detailImages[chunk], let rect = map.viewport.viewRect(for: chunk, in: size) else { continue }
                guard drawTerrainImageLayer(image, rect: rect, interpolation: .none, size: size, scale: scale,
                    lighting: map.lighting, protectsWater: false, contrast: contrast, into: destination) else { return nil }
            }
        }
        let overlays = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            MapView.drawOverlays(viewport: map.viewport, regions: visible, content: content,
                                 portalStatus: portalStatus, in: context, size: size)
        }
        .modifier(MapLegendOverlay(layers: content))
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, locale)
        guard drawImageLayer(overlays, size: size, scale: scale, into: destination),
              let image = destination.makeImage() else { return nil }
        return png(image)
    }

    /// Custom SwiftUI shaders require ImageRenderer.cgImage; its CGContext callback ignores
    /// them. Rasterize only the visible part of this region, in at most 1024-pixel squares,
    /// before compositing. A large area export never allocates a second full-size terrain image.
    @MainActor
    static func drawTerrainLayer(_ tile: MapTileImage, region: RegionPosition, viewport: MapViewport,
                                 size: CGSize, scale: CGFloat, lighting: MapLighting?, protectsWater: Bool,
                                 contrast: ColorSchemeContrast, into destination: CGContext) -> Bool {
        guard let rect = viewport.viewRect(for: region, in: size) else { return true }
        return drawTerrainImageLayer(tile, rect: rect.insetBy(dx: -0.5, dy: -0.5),
            interpolation: viewport.scale >= 1 ? .none : .medium, size: size, scale: scale,
            lighting: lighting, protectsWater: protectsWater, contrast: contrast, into: destination)
    }

    /// Region and close-up chunk images use the same bounded shader rasterizer.
    @MainActor
    private static func drawTerrainImageLayer(_ tile: MapTileImage, rect: CGRect, interpolation: Image.Interpolation,
                                              size: CGSize, scale: CGFloat, lighting: MapLighting?, protectsWater: Bool,
                                              contrast: ColorSchemeContrast, into destination: CGContext) -> Bool {
        let visible = rect.intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull, !visible.isEmpty else { return true }
        guard lighting != nil, tile.normals != nil else {
            let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                MapView.drawTerrainImage(tile, rect: rect, interpolation: interpolation,
                    lighting: nil, protectsWater: protectsWater, increasedContrast: contrast == .increased, in: context)
            }
            return drawImageLayer(canvas, size: size, scale: scale, into: destination)
        }
        let pixels = CGRect(x: visible.minX * scale, y: visible.minY * scale,
                            width: visible.width * scale, height: visible.height * scale).integral
        for y in stride(from: pixels.minY, to: pixels.maxY, by: 1024) {
            for x in stride(from: pixels.minX, to: pixels.maxX, by: 1024) {
                let crop = CGRect(x: x / scale, y: y / scale, width: min(1024, pixels.maxX - x) / scale,
                                  height: min(1024, pixels.maxY - y) / scale)
                let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    var translated = context
                    translated.translateBy(x: -crop.minX, y: -crop.minY)
                    MapView.drawTerrainImage(tile, rect: rect, interpolation: interpolation,
                        lighting: lighting, protectsWater: protectsWater,
                        increasedContrast: contrast == .increased, in: translated)
                }
                .frame(width: crop.width, height: crop.height)
                let renderer = ImageRenderer(content: canvas)
                renderer.scale = scale
                guard let image = renderer.cgImage else { return false }
                // Canvas is top-left based; the destination bitmap context is bottom-left based.
                let rect = CGRect(x: crop.minX * scale, y: (size.height - crop.maxY) * scale,
                                  width: crop.width * scale, height: crop.height * scale)
                destination.draw(image, in: rect)
            }
        }
        return true
    }

    /// Copy, Share and area export keep the same CGContext rasterizer for nonshader layers,
    /// preserving their existing antialiased edges. Terrain shaders use the bounded helper above.
    @MainActor
    static func drawImageLayer<V: View>(_ layer: V, size: CGSize, scale: CGFloat, into destination: CGContext) -> Bool {
        let renderer = ImageRenderer(content: layer.frame(width: size.width, height: size.height))
        var drawn = false
        renderer.render(rasterizationScale: scale) { _, draw in
            destination.saveGState()
            destination.scaleBy(x: scale, y: scale)
            draw(destination)
            destination.restoreGState()
            drawn = true
        }
        return drawn
    }

    static func imageContext(width: Int, height: Int) -> CGContext? {
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !overflow, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func png(_ image: CGImage) -> MapImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return MapImage(data: data as Data)
    }
}

/// The map's current view, rendered only when it's shared.
nonisolated struct SharedMapImage: Transferable {
    let render: @MainActor @Sendable () -> MapImage?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { shared in
            guard let image = await shared.render() else { throw CocoaError(.fileWriteUnknown) }
            return image.data
        }
    }
}

extension MapImage {
    /// The document's map as currently shown, or `nil` before it is laid out.
    @MainActor
    static func render(session: WorldSession, colorScheme: ColorScheme, locale: Locale, contrast: ColorSchemeContrast) -> MapImage? {
        guard let map = session.map, let shown = map.shownSize else { return nil }
        return render(map, content: MapContent(session: session),
                      portalStatus: { [weak session] in session?.presentation.linkStatus(for: $0) },
                      size: shown.size, scale: shown.displayScale, colorScheme: colorScheme, locale: locale, contrast: contrast)
    }
}
