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
                       size: CGSize, scale: CGFloat, colorScheme: ColorScheme, locale: Locale) -> MapImage? {
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            MapView.drawMap(map, content: content, portalStatus: portalStatus, displayScale: scale, in: context, size: size)
        }
        .frame(width: size.width, height: size.height)
        .modifier(MapLegendOverlay(layers: content))
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, locale)
        guard scale.isFinite, scale > 0,
              let width = Int(exactly: (size.width * scale).rounded(.up)),
              let height = Int(exactly: (size.height * scale).rounded(.up)),
              let destination = imageContext(width: width, height: height),
              drawImageLayer(canvas, size: size, scale: scale, into: destination),
              let image = destination.makeImage() else { return nil }
        return png(image)
    }

    /// Copy, Share and area export use the same rasterizer. ImageRenderer.cgImage and a
    /// CGContext-backed render differ at antialiased edges, even with the same Canvas commands.
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
    static func render(session: WorldSession, colorScheme: ColorScheme, locale: Locale) -> MapImage? {
        guard let map = session.map, let shown = map.shownSize else { return nil }
        return render(map, content: MapContent(session: session),
                      portalStatus: { [weak session] in session?.presentation.linkStatus(for: $0) },
                      size: shown.size, scale: shown.displayScale, colorScheme: colorScheme, locale: locale)
    }
}
