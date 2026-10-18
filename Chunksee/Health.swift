import Foundation
import SwiftUI

/// Saved health uses the same row, gauge and hearts precision for players and every creature.
struct HealthRow: View {
    let health: Double?
    let maximum: Double?
    @Environment(\.locale) private var locale

    var body: some View {
        let reading = HealthPresentation(health: health, maximum: maximum)
        if let text = reading.text(locale: locale) {
            let label: LocalizedStringKey = reading.health == nil ? "Maximum Health" : "Health"
            LabeledContent(label) {
                if let value = reading.gaugeValue, let maximum = reading.maximum {
                    Gauge(value: value, in: 0...maximum) { EmptyView() } currentValueLabel: {
                        Text(text).monospacedDigit()
                    }
                    .tint(.red)
                } else {
                    Text(text).monospacedDigit()
                }
            }
            .help("Health recorded when Minecraft last saved")
        }
    }
}

nonisolated struct HealthPresentation: Equatable, Sendable {
    let health: Double?
    let maximum: Double?

    init(health: Double?, maximum: Double?) {
        self.health = health.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.maximum = maximum.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The gauge stays within its range while the text preserves the actual saved value.
    var gaugeValue: Double? {
        guard let health, let maximum else { return nil }
        return min(health, maximum)
    }

    func text(locale: Locale = .current) -> String? {
        guard let health else { return maximum.flatMap { Self.hearts($0, locale: locale) } }
        guard let maximum else { return Self.hearts(health, locale: locale) }
        return CountedText.hearts(health / 2, of: maximum / 2, locale: locale)
    }

    static func hearts(_ health: Double, locale: Locale = .current) -> String? {
        guard health.isFinite, health >= 0 else { return nil }
        return CountedText.hearts(health / 2, locale: locale)
    }
}
