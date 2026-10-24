import ChunkseeKit
import CoreGraphics
import Foundation

/// Display policy for the light above the block shown on the map. Kit owns all light rules.
/// This checks light only, not the terrain, space, biome or other spawning conditions.
nonisolated struct DarkSpots: Equatable, Sendable {
    let rule: MonsterSpawnLight?

    enum Status: UInt8, Sendable {
        case unknown, bright, dark

        var description: String {
            switch self {
            case .unknown: String(localized: "Nighttime light unknown")
            case .bright: String(localized: "Too bright for ordinary monsters at night")
            case .dark: String(localized: "Light low enough for ordinary monsters at night")
            }
        }
    }

    static let symbol = "moon.stars.fill"
    static var explanation: String {
        String(localized: "Light above the displayed surface at night. Other spawning conditions are not checked.")
    }

    /// Only resolved facts affect the cache. Autosaves, a renamed world or identical pack
    /// contents do not change the image; unavailable facts cannot reuse a known result.
    var cacheKey: String {
        guard let rule else { return "unknown" }
        return "\(rule.blockLightLimit).\(rule.maximumRawLight).\(rule.hasSkylight).\(rule.skyDarkening.map(String.init) ?? "none")"
    }

    func status(in chunk: Chunk, x: Int, surfaceY: Int, z: Int) -> Status {
        let y = surfaceY.addingReportingOverflow(1)
        guard !y.overflow, let value = rule?.canPass(in: chunk, x: x, y: y.partialValue, z: z) else { return .unknown }
        return value ? .dark : .bright
    }

    /// Dots distinguish dark areas from bright terrain without relying on red; unknown light
    /// is striped. The map, legend and exports all use these same treatments.
    static func color(_ original: MapColor, status: Status, x: Int, z: Int) -> MapColor {
        switch status {
        case .bright: original
        case .dark:
            original.blended(with: MapColor(x % 4 == 1 && z % 4 == 1 ? 0x682318 : 0xf04f38), amount: 0.6)
        case .unknown:
            original.blended(with: MapColor((x + z) % 4 < 2 ? 0x30343b : 0xc4c8ce), amount: 0.5)
        }
    }

    static func applying(_ light: [UInt8], to pixels: [UInt8], side: Int) -> [UInt8] {
        guard light.count == side * side, pixels.count == light.count * 4 else { return pixels }
        var result = pixels
        for index in light.indices where pixels[index * 4 + 3] != 0 {
            guard let status = Status(rawValue: light[index]), status != .bright else { continue }
            let original = MapColor(UInt32(pixels[index * 4]) << 16 | UInt32(pixels[index * 4 + 1]) << 8 | UInt32(pixels[index * 4 + 2]))
            let color = color(original, status: status, x: index % side, z: index / side)
            result[index * 4] = color.red
            result[index * 4 + 1] = color.green
            result[index * 4 + 2] = color.blue
        }
        return result
    }

    static func sample(_ status: Status) -> CGImage? {
        let side = 8
        var pixels = [UInt8](repeating: 128, count: side * side * 4)
        for i in 0..<(side * side) { pixels[i * 4 + 3] = 255 }
        return CGImage.rgba(applying(Array(repeating: status.rawValue, count: side * side), to: pixels, side: side), width: side, height: side)
    }
}
