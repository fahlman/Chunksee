import CoreGraphics
import Foundation
import SwiftUI

/// Readable names from ids: `minecraft:diamond_sword` → "Diamond Sword". Minecraft's own names
/// live in its language files, which can't be redistributed.
nonisolated enum ReadableName {
    static func from(_ id: String) -> String {
        let base = id.split(separator: ":").last.map(String.init) ?? id
        return base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Block coordinates as lists and readouts show them: "X 10  Z -2".
nonisolated enum Coordinates {
    static func text(x: Double, z: Double) -> String {
        "X \(Int(x.rounded(.down)))  Z \(Int(z.rounded(.down)))"
    }

    static func text(_ point: CGPoint) -> String { text(x: point.x, z: point.y) }

    /// X, Y and Z together, in Minecraft's order.
    static func text(_ point: CGPoint, y: Int) -> String {
        "X \(Int(point.x.rounded(.down)))  Y \(y)  Z \(Int(point.y.rounded(.down)))"
    }
}

extension Color {
    /// An sRGB color from hex, as the layer groups define their colors.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(_ color: MapColor) {
        self.init(hex: UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue))
    }
}

extension CGImage {
    /// An sRGB image from premultiplied RGBA pixels, row by row from the top left.
    nonisolated static func rgba(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard pixels.count == width * height * 4, let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
