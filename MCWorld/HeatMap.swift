import CoreGraphics
import MCWorldKit
import SwiftUI

/// The time-spent heat map: each chunk colored by how long players spent near it
/// (`InhabitedTime`), on a fixed logarithmic scale so colors don't shift while regions load.
nonisolated enum HeatMap {
    /// Below a minute, chunks are left clear: players only passed by.
    static let minimumTicks = 1_200
    /// A thousand hours and more is the hottest color.
    static let maximumTicks = 72_000 * 1_000

    /// Position on the scale, 0 (a minute) to 1 (a thousand hours), or `nil` for too little time.
    static func level(ofTicks ticks: Int) -> Double? {
        guard ticks >= minimumTicks else { return nil }
        let low = log10(Double(minimumTicks)), high = log10(Double(maximumTicks))
        return min(max((log10(Double(ticks)) - low) / (high - low), 0), 1)
    }

    /// Blue through green and yellow to red.
    static func hue(atLevel level: Double) -> Double { 0.66 * (1 - level) }

    /// One region's chunks as a 32×32 image, row by row from the north-west; `nil` if no chunk
    /// has enough time to show.
    static func image(fromTicks ticks: [Int]) -> CGImage? {
        guard ticks.count == 1024 else { return nil }
        var pixels = [UInt8](repeating: 0, count: 1024 * 4)
        var any = false
        for (index, value) in ticks.enumerated() {
            guard let level = level(ofTicks: value) else { continue }
            any = true
            let (red, green, blue) = rgb(hue: hue(atLevel: level))
            // Premultiplied by the 70% opacity.
            pixels[index * 4] = UInt8(red * 0.7 * 255)
            pixels[index * 4 + 1] = UInt8(green * 0.7 * 255)
            pixels[index * 4 + 2] = UInt8(blue * 0.7 * 255)
            pixels[index * 4 + 3] = UInt8(0.7 * 255)
        }
        guard any, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Full-saturation, full-brightness HSB to RGB.
    static func rgb(hue: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return (1, x, 0)
        case 1: return (x, 1, 0)
        case 2: return (0, 1, x)
        case 3: return (0, x, 1)
        case 4: return (x, 0, 1)
        default: return (1, 0, x)
        }
    }

    /// Every region's heat image in a dimension, read in parallel; regions with nothing to show
    /// are left out.
    @concurrent
    static func images(for dimension: MCWorldKit.Dimension) async -> [RegionCoordinate: CGImage] {
        await withTaskGroup(of: (RegionCoordinate, CGImage?).self) { group in
            for region in dimension.regionFiles() {
                group.addTask {
                    guard !Task.isCancelled else { return (RegionCoordinate(x: region.x, z: region.z), nil) }
                    // Read into a local first: Swift 6.4 release builds can misread values captured
                    // next to an awaited call in task-group children (see #6).
                    let ticks = (try? dimension.inhabitedTimes(regionX: region.x, regionZ: region.z)) ?? []
                    let image = image(fromTicks: ticks)
                    return (RegionCoordinate(x: region.x, z: region.z), image)
                }
            }
            var images: [RegionCoordinate: CGImage] = [:]
            for await (region, image) in group {
                if let image { images[region] = image }
            }
            return images
        }
    }
}

/// The heat map's color scale.
struct HeatMapLegend: View {
    var isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Time Spent").font(.headline)
                if isLoading { ProgressView().controlSize(.small) }
            }
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Color(hue: HeatMap.hue(atLevel: $0), saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 200, height: 10)
                .clipShape(Capsule())
            // Labels sit where their times fall on the logarithmic scale.
            ZStack {
                label("1 min", ticks: HeatMap.minimumTicks, anchor: 0)
                label("1 hour", ticks: 72_000, anchor: 0.5)
                label("1,000 hours", ticks: HeatMap.maximumTicks, anchor: 1)
            }
            .font(.caption)
            .frame(width: 200, height: 14)
            Text("Time the game recorded near each chunk")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// A label at a time's place on the 200-point bar; `anchor` 0 puts its leading edge there.
    private func label(_ text: LocalizedStringKey, ticks: Int, anchor: CGFloat) -> some View {
        Text(text)
            .fixedSize()
            .alignmentGuide(HorizontalAlignment.center) { $0.width * anchor }
            .frame(width: 200, alignment: .center)
            .offset(x: (HeatMap.level(ofTicks: ticks) ?? 0) * 200 - 100)
    }
}
