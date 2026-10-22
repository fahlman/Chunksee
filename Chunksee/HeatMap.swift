import CoreGraphics
import ChunkseeKit
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
        return any ? CGImage.rgba(pixels, width: 32, height: 32) : nil
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
    static func images(_ reader: RegionReader, previous: [RegionPosition: CGImage]) async -> [RegionPosition: CGImage] {
        let available = Set(reader.dimension.regionFiles().map { RegionPosition(x: $0.x, z: $0.z) })
        var images = previous.filter { available.contains($0.key) }
        for part in await reader.everyRegion({ await $0.facts($1) }) {
            guard let facts = part.value else { continue }
            images[part.region] = image(fromTicks: facts.inhabitedTimes)
        }
        return images
    }
}

/// One dimension document's heat map, read when first shown and again after the game saves.
@Observable
final class HeatMapLayer {
    var isShown = false {
        didSet {
            guard !loader.isClosed, isShown != oldValue else { return }
            rememberedVisibility?.rememberTimeSpent(isShown)
            load()
        }
    }
    private let loader: RefreshLoader<[RegionPosition: CGImage]>
    private let hasReader: Bool
    @ObservationIgnored private var rememberedVisibility: LayerVisibility?
    init(reader: RegionReader?, work: BackgroundWork) {
        hasReader = reader != nil
        loader = RefreshLoader(work: work, priority: .userInitiated) { previous in
            guard let reader else { return [:] }
            return await HeatMap.images(reader, previous: previous ?? [:])
        }
    }

    /// Restores this tab's flag without making a second live copy in LayerVisibility.
    func restoreVisibility(from visibility: LayerVisibility) {
        guard !loader.isClosed else { return }
        rememberedVisibility = visibility
        isShown = visibility.rememberedTimeSpent
    }

    /// This document's images, when the layer is on and they've been read.
    var visibleImages: [RegionPosition: CGImage]? {
        isShown ? loader.value : nil
    }

    var isLoading: Bool { isShown && hasReader && loader.value == nil }

    /// Reads the shown dimension's images if needed, or again with `reread` after the game saved;
    /// the current ones stay until the new ones are ready.
    func load(reread: Bool = false) {
        loader.request(isEnabled: isShown && hasReader, reread: reread)
    }

    func waitForReads() async {
        await loader.waitUntilFinished()
    }

    func cancel() {
        loader.close()
    }
}

/// The heat map's color scale.
struct HeatMapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Time Spent").font(.headline)
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Color(hue: HeatMap.hue(atLevel: $0), saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 200, height: 10)
                .clipShape(Capsule())
            // Labels sit where their times fall on the logarithmic scale.
            ZStack {
                label(ticks: HeatMap.minimumTicks, anchor: 0)
                label(ticks: 72_000, anchor: 0.5)
                label(ticks: HeatMap.maximumTicks, anchor: 1)
            }
            .font(.caption)
            .frame(width: 200, height: 14)
            Text("Time the game recorded near each chunk")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A label at a time's place on the 200-point bar; `anchor` 0 puts its leading edge there.
    private func label(ticks: Int, anchor: CGFloat) -> some View {
        Text(GameDuration.fromTicks(ticks), format: GameDuration.units())
            .fixedSize()
            .alignmentGuide(HorizontalAlignment.center) { $0.width * anchor }
            .frame(width: 200, alignment: .center)
            .offset(x: (HeatMap.level(ofTicks: ticks) ?? 0) * 200 - 100)
    }
}
