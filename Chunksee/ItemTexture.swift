import ChunkseeKit
import CoreGraphics
import Foundation
import ImageIO

/// Decoded pixels have a top-left origin and premultiplied RGBA channels.
nonisolated struct ItemTexture: Sendable, Encodable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    init?(png: Data) {
        guard let source = PNG(png) else { return nil }
        self.init(image: source.image)
    }

    init?(png: Data, paletteKey: Data, palette: Data) {
        guard let source = PNG(png), let original = source.argbPixels(),
              let key = PNG(paletteKey, maxPixels: 4096)?.argbPixels(),
              let palette = PNG(palette, maxPixels: 4096)?.argbPixels(),
              let mapping = AssetPaletteMapping(key: key, palette: palette) else { return nil }
        var rgba = [UInt8]()
        rgba.reserveCapacity(original.count * 4)
        for pixel in original {
            let color = mapping.color(pixel)
            rgba.append(UInt8(truncatingIfNeeded: color >> 16))
            rgba.append(UInt8(truncatingIfNeeded: color >> 8))
            rgba.append(UInt8(truncatingIfNeeded: color))
            rgba.append(UInt8(truncatingIfNeeded: color >> 24))
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: source.image.width, height: source.image.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: source.image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        self.init(image: image)
    }

    /// Apply a resolved material layer in premultiplied RGBA, before model projection/lighting.
    /// The verified skins share their dimensions; incompatible resources keep the usual fallback.
    func compositing(_ layer: ItemTexture, color: UInt32) throws -> ItemTexture? {
        try Task.checkCancellation()
        guard (1...1024).contains(width), (1...1024).contains(height),
              layer.width == width, layer.height == height,
              pixels.count == width * height * 4, layer.pixels.count == pixels.count else { return nil }
        let tint = SIMD3<Float>(Float((color >> 16) & 255), Float((color >> 8) & 255), Float(color & 255)) / 255
        var output = pixels
        for y in 0..<height {
            try Task.checkCancellation()
            for index in stride(from: y * width * 4, to: (y + 1) * width * 4, by: 4) {
                let remaining = 1 - Float(layer.pixels[index + 3]) / 255
                for channel in 0..<3 {
                    let value = Float(layer.pixels[index + channel]) * tint[channel]
                        + Float(output[index + channel]) * remaining
                    output[index + channel] = UInt8(clamping: Int(value.rounded()))
                }
                let alpha = Float(layer.pixels[index + 3]) + Float(output[index + 3]) * remaining
                output[index + 3] = UInt8(clamping: Int(alpha.rounded()))
            }
        }
        return ItemTexture(width: width, height: height, pixels: output)
    }

    private init?(image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    func rgb(at pixel: SIMD2<Int>) -> UInt32? {
        guard (0..<width).contains(pixel.x), (0..<height).contains(pixel.y) else { return nil }
        let index = (pixel.y * width + pixel.x) * 4
        guard pixels[index + 3] == 255 else { return nil }
        return UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
    }

    /// Mean visible color in sRGB. Premultiplied channels weight partially transparent pixels;
    /// unused transparent parts of a skin do not darken the result.
    func representativeColor() throws -> MapColor? {
        guard (1...1024).contains(width), (1...1024).contains(height), pixels.count == width * height * 4 else { return nil }
        var red = 0, green = 0, blue = 0, alpha = 0
        for y in 0..<height {
            try Task.checkCancellation()
            for offset in stride(from: y * width * 4, to: (y + 1) * width * 4, by: 4) {
                red += Int(pixels[offset]); green += Int(pixels[offset + 1]); blue += Int(pixels[offset + 2])
                alpha += Int(pixels[offset + 3])
            }
        }
        guard alpha > 0 else { return nil }
        return MapColor(UInt32(min(255, red * 255 / alpha)) << 16
            | UInt32(min(255, green * 255 / alpha)) << 8 | UInt32(min(255, blue * 255 / alpha)))
    }

    private struct PNG {
        let image: CGImage

        init?(_ data: Data, maxPixels: Int = 1024 * 1024) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...1024).contains(width), (1...1024).contains(height), width * height <= maxPixels,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == width, image.height == height else { return nil }
            self.image = image
        }

        /// Palette matching needs the original RGB, before CGContext multiplies by alpha.
        /// ImageIO exposes the installed game's PNGs as 8-bit gray/RGB with straight alpha.
        /// Unsupported layouts are unavailable instead of matching rounded or converted keys.
        func argbPixels() -> [UInt32]? {
            guard image.bitsPerComponent == 8 else { return nil }
            let colors: Int
            switch image.colorSpace?.model {
            case .rgb: colors = 3
            case .monochrome: colors = 1
            default: return nil
            }
            let components: Int, firstColor: Int, alpha: Int?
            switch image.alphaInfo {
            case .none: components = colors; firstColor = 0; alpha = nil
            case .last: components = colors + 1; firstColor = 0; alpha = colors
            case .first: components = colors + 1; firstColor = 1; alpha = 0
            case .noneSkipLast: components = colors + 1; firstColor = 0; alpha = nil
            case .noneSkipFirst: components = colors + 1; firstColor = 1; alpha = nil
            default: return nil
            }
            let order = image.bitmapInfo.intersection(.byteOrderMask)
            guard order == .byteOrderDefault || order == .byteOrder32Big || order == .byteOrder16Big,
                  image.bitsPerPixel == components * 8, image.bytesPerRow >= image.width * components,
                  let data = image.dataProvider?.data,
                  CFDataGetLength(data) >= image.bytesPerRow * image.height,
                  let bytes = CFDataGetBytePtr(data) else { return nil }
            var result = [UInt32]()
            result.reserveCapacity(image.width * image.height)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * image.bytesPerRow + x * components
                    let r = UInt32(bytes[offset + firstColor])
                    let g = colors == 1 ? r : UInt32(bytes[offset + firstColor + 1])
                    let b = colors == 1 ? r : UInt32(bytes[offset + firstColor + 2])
                    let a = alpha.map { UInt32(bytes[offset + $0]) } ?? 255
                    result.append(a << 24 | r << 16 | g << 8 | b)
                }
            }
            return result
        }
    }
}
