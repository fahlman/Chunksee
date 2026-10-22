import ChunkseeKit
import CoreGraphics
import Foundation

/// Geometry is checked before allocating an image or starting any terrain reads.
nonisolated struct MapExportPlan: Equatable, Sendable {
    // A 16-million-pixel RGBA destination costs 64 MiB. Encoding and the final image
    // may need additional copies, but the destination never grows with the world.
    static let maximumPixels = 16_777_216
    static let maximumSide = 16_384
    static let blocksPerPixelChoices = (0...24).map { 1 << $0 }

    let bounds: CGRect
    let blocksPerPixel: Int
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: width, height: height) }
    var uncompressedBytes: Int { width * height * 4 }
    var viewport: MapViewport {
        let scale = 1 / CGFloat(blocksPerPixel)
        // Rounding the image up adds space at its right/bottom edges, without shifting its origin.
        return MapViewport(center: CGPoint(x: bounds.minX + CGFloat(width) / scale / 2,
                                           y: bounds.minY + CGFloat(height) / scale / 2), scale: scale)
    }

    init(bounds: CGRect, blocksPerPixel: Int) throws {
        guard [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              bounds.size.width > 0, bounds.size.height > 0,
              Self.blocksPerPixelChoices.contains(blocksPerPixel) else { throw Failure.invalidArea }
        let wide = (bounds.width / CGFloat(blocksPerPixel)).rounded(.up)
        let high = (bounds.height / CGFloat(blocksPerPixel)).rounded(.up)
        guard wide >= 1, high >= 1, wide <= CGFloat(Self.maximumSide), high <= CGFloat(Self.maximumSide),
              let width = Int(exactly: wide), let height = Int(exactly: high),
              width <= Self.maximumPixels / height else { throw Failure.tooLarge }
        self.bounds = bounds
        self.blocksPerPixel = blocksPerPixel
        self.width = width
        self.height = height
        guard viewport.isValid else { throw Failure.invalidArea }
    }

    static func visibleBounds(viewport: MapViewport, size: CGSize) -> CGRect? {
        guard viewport.isValid, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: viewport.blockPoint(at: .zero, in: size),
                      size: CGSize(width: size.width / viewport.scale, height: size.height / viewport.scale))
    }

    static func measuredBounds(_ ruler: MapRuler) -> CGRect? {
        guard let start = ruler.start, let end = ruler.end else { return nil }
        // Include both endpoint blocks, including a one-block-wide or one-block-high selection.
        return CGRect(x: Double(min(start.x, end.x)), y: Double(min(start.z, end.z)),
                      width: abs(Double(end.x) - Double(start.x)) + 1,
                      height: abs(Double(end.z) - Double(start.z)) + 1)
    }

    enum Failure: LocalizedError, Equatable {
        case invalidArea, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidArea: String(localized: "Choose an area of the map to export.")
            case .tooLarge: String(localized: "Choose a smaller scale or area. Images can have up to 16 million pixels and 16,384 pixels on either side.")
            }
        }
    }
}
