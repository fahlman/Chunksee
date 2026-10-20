import Foundation
import SwiftUI

/// Status values use the same number styling and describe the same saved snapshot.
struct SavedStatusRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        LabeledContent(title) { content.monospacedDigit() }
            .help("Recorded when Minecraft last saved")
    }
}

/// Saved health uses the same row, gauge and hearts precision for players and every creature.
struct HealthRow: View {
    let health: Double?
    let maximum: Double?
    @Environment(\.locale) private var locale

    var body: some View {
        let reading = HealthPresentation(health: health, maximum: maximum)
        if let text = reading.text(locale: locale) {
            let label: LocalizedStringKey = reading.health == nil ? "Maximum Health" : "Health"
            SavedStatusRow(label) {
                if let value = reading.gaugeValue, let maximum = reading.maximum {
                    Gauge(value: value, in: 0...maximum) { EmptyView() } currentValueLabel: {
                        Text(text)
                    }
                    .tint(.red)
                } else {
                    Text(text)
                }
            }
        }
    }
}

/// Both the gauge and its label count the game's half-drumstick food points identically.
nonisolated struct HungerPresentation: Equatable, Sendable {
    private static let maximumFood = 20
    let food: Int

    var value: Double { Self.drumsticks(food) }
    var maximum: Double { Self.drumsticks(Self.maximumFood) }
    var gaugeValue: Double { min(value, maximum) }

    private static func drumsticks(_ food: Int) -> Double { Double(food) / 2 }
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
        return CountedText.hearts(of: maximum / 2).locale(locale).format(health / 2)
    }

    static func hearts(_ health: Double, locale: Locale = .current) -> String? {
        guard health.isFinite, health >= 0 else { return nil }
        return CountedText.hearts.locale(locale).format(health / 2)
    }
}
