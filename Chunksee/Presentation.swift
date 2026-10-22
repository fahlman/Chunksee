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

/// Coordinate digits keep the same width in sidebar captions, detail rows and map readouts.
/// Coordinates within prose keep the paragraph's normal typography.
struct CoordinateText: View {
    private let text: Text

    init(_ coordinates: Coordinates, dimension: String? = nil) {
        text = Text(coordinates, format: Coordinates.Style(dimension: dimension))
    }

    init(_ text: Text) { self.text = text }

    var body: some View { text.monospacedDigit() }
}

/// Every location row shows only its icon and name; ancillary information belongs in its inspector.
struct LocationLabel<Icon: View>: View {
    let title: Text
    var isDimmed = false
    @ViewBuilder var icon: Icon

    var body: some View {
        Label {
            title.lineLimit(2)
        } icon: {
            icon
        }
        .opacity(isDimmed ? MarkerStyle.dimmedOpacity : 1)
    }
}

/// Sidebar actions share a native icon/title row while keeping their Button or SettingsLink.
struct SidebarActionRow<Content: View>: View {
    let help: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        content
            .buttonStyle(.plain)
            .labelStyle(.titleAndIcon)
            .help(help)
    }
}

/// A map position with an optional saved height; formatting never invents a missing Y.
nonisolated struct Coordinates: Equatable, Sendable {
    let point: CGPoint
    let y: Double?

    init(_ point: CGPoint, y: Double? = nil) {
        self.point = point
        self.y = y
    }

    init(_ point: CGPoint, y: Int) {
        self.init(point, y: Double(y))
    }

    /// Unreadable saved positions have no block coordinate; conversion must never trap.
    static func block(_ value: Double) -> Int? { BlockPosition.coordinate(containing: value) }

    var isMappable: Bool {
        BlockPosition.mapCoordinates(x: point.x, y: y, z: point.y) != nil
    }

    static func canLocate(x: Double, y: Double, z: Double) -> Bool {
        Coordinates(CGPoint(x: x, y: z), y: y).isMappable
    }

    static func text(x: Double, z: Double) -> String {
        text(CGPoint(x: x, y: z))
    }

    static func text(_ point: CGPoint, y: Double? = nil, dimension: String? = nil) -> String {
        Style(dimension: dimension).format(Coordinates(point, y: y))
    }

    /// X, Y and Z together, in Minecraft's order.
    static func text(_ point: CGPoint, y: Int, dimension: String? = nil) -> String {
        text(point, y: Double(y), dimension: dimension)
    }

    /// Display labels keep Minecraft's axis order and ungrouped block numbers.
    nonisolated struct Style: FormatStyle, Sendable {
        private var dimension: String?
        private var locale: Locale = .autoupdatingCurrent

        init(dimension: String? = nil) { self.dimension = dimension }

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ coordinates: Coordinates) -> String {
            guard let x = Coordinates.block(coordinates.point.x), let z = Coordinates.block(coordinates.point.y) else {
                return String(localized: "Location unknown", locale: locale)
            }
            var value = "X \(x)"
            if let y = coordinates.y {
                guard let y = Coordinates.block(y) else { return String(localized: "Location unknown", locale: locale) }
                value += "  Y \(y)"
            }
            value += "  Z \(z)"
            return dimension.map { "\($0) · \(value)" } ?? value
        }
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
