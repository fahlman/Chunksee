import ChunkseeKit
import SwiftUI

/// Kit owns saved wear; presentation owns the game's 13-step bar and green-to-red tint.
nonisolated struct DurabilityPresentation: Equatable, Sendable {
    let wear: ItemDurability

    init?(_ wear: ItemDurability?) {
        guard let wear, wear.maximum > 0, (0...wear.maximum).contains(wear.remaining) else { return nil }
        self.wear = wear
    }

    var isDamaged: Bool { wear.remaining < wear.maximum }

    // Minecraft Item.getBarWidth uses Float arithmetic, rounding only the final width.
    var barPixels: Int {
        let damage = Float(wear.maximum - wear.remaining)
        return min(13, max(0, Int((13 - damage * 13 / Float(wear.maximum)).rounded())))
    }

    var hue: Double {
        let maximum = Float(wear.maximum)
        let damage = Float(wear.maximum - wear.remaining)
        return Double(max(0, (maximum - damage) / maximum) / 3)
    }

    var color: Color { Color(hue: hue, saturation: 1, brightness: 1) }
}

struct DurabilityRow: View {
    let reading: DurabilityPresentation
    @Environment(\.locale) private var locale

    var body: some View {
        SavedStatusRow("Durability") {
            SavedStatusGauge(value: Double(reading.wear.remaining), maximum: Double(reading.wear.maximum)) {
                Text(ItemAppearance.durability(reading.wear, includingLabel: false, locale: locale))
            }
            .tint(reading.color)
        }
    }
}

/// Slot bars retain Minecraft's discrete width and black backing; the slot owns spoken details.
struct InventoryDurabilityBar: View {
    let reading: DurabilityPresentation
    private let pixel: CGFloat = 1.5

    var body: some View {
        Rectangle().fill(.black)
            .frame(width: 13 * pixel, height: 2 * pixel)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(reading.color)
                    .frame(width: CGFloat(reading.barPixels) * pixel, height: pixel)
            }
            .accessibilityHidden(true)
    }
}
