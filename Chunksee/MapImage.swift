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
                       size: CGSize, scale: CGFloat) -> MapImage? {
        let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            MapView.drawMap(map, content: content, portalStatus: portalStatus, displayScale: scale, in: context, size: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
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
    static func render(session: WorldSession) -> MapImage? {
        guard let map = session.map, let shown = map.shownSize else { return nil }
        return render(map, content: MapContent(session: session),
                      portalStatus: { [weak session] in session?.presentation.linkStatus(for: $0) },
                      size: shown.size, scale: shown.displayScale)
    }
}
