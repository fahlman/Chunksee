import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI

/// Readable names from ids: `minecraft:diamond_sword` → "Diamond Sword". Minecraft's own names
/// live in its language files, which can't be redistributed.
nonisolated enum ReadableName {
    static func from(_ id: String) -> String {
        let base = identifierPath(id)
        return base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Only vanilla IDs participate in the app’s vanilla names, colors and categories.
    static func vanillaPath(_ id: String) -> String? {
        guard let parsed = Identifier(id), parsed.namespace == "minecraft" else { return nil }
        return parsed.path
    }

    /// Kit parses IDs; presentation keeps an unfamiliar/malformed value visible as a fallback.
    static func identifierPath(_ id: String) -> String {
        guard let parsed = Identifier(id), !parsed.path.isEmpty else { return id }
        return parsed.path
    }
}

/// The same level numerals for equipment and effects; each caller decides when to show a level.
nonisolated enum LevelText {
    static func numeral(_ level: Int) -> String {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        return (1...numerals.count).contains(level) ? numerals[level - 1] : String(level)
    }
}

/// Block coordinates as lists and readouts show them: "X 10  Z -2".
nonisolated enum Coordinates {
    /// Unreadable saved positions have no block coordinate; conversion must never trap.
    static func block(_ value: Double) -> Int? { BlockPosition.coordinate(containing: value) }

    static func canLocate(x: Double, y: Double, z: Double) -> Bool {
        MapCoordinates(point: CGPoint(x: x, y: z)) != nil && block(y) != nil
    }

    static func text(x: Double, z: Double) -> String {
        text(CGPoint(x: x, y: z))
    }

    static func text(_ point: CGPoint, y: Double? = nil, dimension: String? = nil) -> String {
        guard let x = block(point.x), let z = block(point.y) else { return String(localized: "Location unknown") }
        var value = "X \(x)"
        if let y {
            guard let y = block(y) else { return String(localized: "Location unknown") }
            value += "  Y \(y)"
        }
        value += "  Z \(z)"
        return dimension.map { "\($0) · \(value)" } ?? value
    }

    /// X, Y and Z together, in Minecraft's order.
    static func text(_ point: CGPoint, y: Int, dimension: String? = nil) -> String {
        text(point, y: Double(y), dimension: dimension)
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
