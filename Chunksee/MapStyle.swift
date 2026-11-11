import ChunkseeKit
import CoreGraphics
import Foundation
import SwiftUI

/// A dimension's terrain presentation. The scan and its selected column stay the same.
nonisolated enum MapStyle: String, CaseIterable, Sendable, Codable {
    case normal, height, waterDepth

    /// These are style rules, not saved choices. Consumers use this declaration instead of
    /// deciding independently whether Height participates in a drawing operation.
    struct Inputs: Sendable {
        let materialColors: Bool
        let lighting: Bool
        let shadows: Bool
        let detail: Bool
        let requiresHeightScale: Bool
    }

    var inputs: Inputs {
        switch self {
        case .normal, .waterDepth:
            Inputs(materialColors: true, lighting: true, shadows: true, detail: true, requiresHeightScale: false)
        case .height:
            Inputs(materialColors: false, lighting: false, shadows: false, detail: false, requiresHeightScale: true)
        }
    }

    func isAvailable(heightScale: MapHeightScale?) -> Bool {
        !inputs.requiresHeightScale || heightScale != nil
    }

    func resolved(heightScale: MapHeightScale?) -> Self {
        isAvailable(heightScale: heightScale) ? self : .normal
    }

    var title: LocalizedStringResource {
        switch self {
        case .normal: "Normal"
        case .height: "Height"
        case .waterDepth: "Water Depth"
        }
    }
}

struct MapStyleOptions: View {
    let map: MapModel?

    var body: some View {
        ForEach(MapStyle.allCases, id: \.self) { style in
            // Native toggles honor per-item availability, unlike inline Picker options.
            Toggle(isOn: Binding {
                map?.style == style
            } set: { _ in
                // Choosing an already checked Normal still replaces an unavailable Height choice.
                map?.setStyle(style)
            }) {
                Text(style.title)
            }
            .disabled(map?.canShowStyle(style) != true)
        }
    }
}

/// One fixed scale for height colouring, derived from saved facts rather than loaded tiles.
/// Sea level is the palette's midpoint, even when it lies outside the build range.
nonisolated struct MapHeightScale: Hashable, Sendable, Encodable {
    let bounds: ClosedRange<Int>
    let seaLevel: Int?

    init?(settings: DimensionSettings?) {
        guard let bounds = settings?.type?.buildRange else { return nil }
        self.bounds = bounds
        seaLevel = settings?.noiseGeneration?.seaLevel
    }

    func level(at y: Int) -> Double {
        let y = Double(min(max(y, bounds.lowerBound), bounds.upperBound))
        let low = Double(bounds.lowerBound), high = Double(bounds.upperBound)
        guard let seaLevel else { return (y - low) / (high - low) }
        let sea = Double(seaLevel)
        if y == sea { return 0.5 }
        if y < sea { return 0.5 * (y - low) / (sea - low) }
        return 0.5 + 0.5 * (y - sea) / (high - sea)
    }

}

/// Both the tile pixels and their legend sample these fixed, lightness-ordered ramps.
/// Core Graphics converts evenly spaced Lab colours to sRGB once, away from the pixel loop.
nonisolated enum MapStylePalette {
    static let height = ramp(from: (22, 16, -28), to: (92, -5, 45))
    static let waterDepth = ramp(from: (86, -5, -20), to: (28, -5, -20))

    static func heightColor(y: Int, scale: MapHeightScale) -> MapColor {
        height[Int((scale.level(at: y) * Double(height.count - 1)).rounded())]
    }

    static func waterColor(depth: Int) -> MapColor {
        let level = Double(min(max(depth, 1), RegionTileRenderer.maximumWaterDepth) - 1)
            / Double(RegionTileRenderer.maximumWaterDepth - 1)
        return waterDepth[Int((level * Double(waterDepth.count - 1)).rounded())]
    }

    private static func ramp(from start: (Double, Double, Double), to end: (Double, Double, Double)) -> [MapColor] {
        let lab = CGColorSpace(name: CGColorSpace.genericLab)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)
        return (0..<256).map { index in
            let t = Double(index) / 255
            let lightness = start.0 + (end.0 - start.0) * t
            let components = [lightness, start.1 + (end.1 - start.1) * t, start.2 + (end.2 - start.2) * t, 1].map { CGFloat($0) }
            let converted = lab.flatMap { CGColor(colorSpace: $0, components: components) }
                .flatMap { color in rgb.flatMap { color.converted(to: $0, intent: .relativeColorimetric, options: nil) } }?.components
            // These system colour spaces are available on macOS; a missing conversion keeps
            // an ordered neutral scale rather than losing the map's height/depth information.
            func byte(_ channel: Int) -> UInt32 {
                UInt32((min(max(converted?[channel] ?? CGFloat(lightness / 100), 0), 1) * 255).rounded())
            }
            return MapColor(byte(0) << 16 | byte(1) << 8 | byte(2))
        }
    }
}

struct MapStyleLegend: View {
    let style: MapStyle
    let heightScale: MapHeightScale?

    var body: some View {
        if style == .height, let heightScale {
            VStack(alignment: .leading, spacing: 4) {
                Text(style.title).font(.headline)
                MapLegendScale(colors: heightColors(heightScale), labels: heightLabels(heightScale),
                               marker: seaPosition(heightScale))
                if let sea = heightScale.seaLevel {
                    Text("Sea Level: \(sea.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    if !heightScale.bounds.contains(sea) {
                        Text("Sea level is outside the build range.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Sea level unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("map-height-legend")
        } else if style == .waterDepth {
            let cap = RegionTileRenderer.maximumWaterDepth
            let middle = (cap + 1) / 2
            VStack(alignment: .leading, spacing: 4) {
                Text(style.title).font(.headline)
                MapLegendScale(colors: MapStylePalette.waterDepth.map(color), labels: [
                    .init(text: Text(1, format: .number), position: 0, anchor: 0),
                    .init(text: Text(middle, format: .number), position: Double(middle - 1) / Double(cap - 1), anchor: 0.5),
                    .init(text: Text("\(RegionTileRenderer.maximumWaterDepth.formatted()) or deeper"), position: 1, anchor: 1)
                ])
                Text("Contiguous water blocks").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("map-water-depth-legend")
        }
    }

    private func color(_ value: MapColor) -> Color {
        Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    private func heightColors(_ scale: MapHeightScale) -> [Color] {
        let low = scale.level(at: scale.bounds.lowerBound), high = scale.level(at: scale.bounds.upperBound)
        return (0..<256).map { index in
            color(MapStylePalette.height[Int(((low + (high - low) * Double(index) / 255) * 255).rounded())])
        }
    }

    private func seaPosition(_ scale: MapHeightScale) -> Double? {
        guard let sea = scale.seaLevel, scale.bounds.contains(sea) else { return nil }
        let low = scale.level(at: scale.bounds.lowerBound), high = scale.level(at: scale.bounds.upperBound)
        return (0.5 - low) / (high - low)
    }

    private func heightLabels(_ scale: MapHeightScale) -> [MapLegendScale.Label] {
        var labels: [MapLegendScale.Label] = [
            .init(text: Text(scale.bounds.lowerBound, format: .number), position: 0, anchor: 0),
            .init(text: Text(scale.bounds.upperBound, format: .number), position: 1, anchor: 1)
        ]
        if let sea = scale.seaLevel, let position = seaPosition(scale), position > 0, position < 1 {
            labels.insert(.init(text: Text(sea, format: .number), position: position, anchor: 0.5), at: 1)
        }
        return labels
    }
}
