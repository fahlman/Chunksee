import ChunkseeKit
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A PNG of the map as shown, for File ▸ Export Map Image….
nonisolated struct MapImage: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }

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
