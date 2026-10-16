import ChunkseeKit
import SwiftUI

struct PlayerHealthRow: View {
    let player: PlayerInfo

    var body: some View {
        let maximum = player.maxHealth
        if let health = player.health, health.isFinite, health >= 0 {
            LabeledContent("Health") {
                if let maximum, maximum.isFinite, maximum > 0 {
                    Gauge(value: min(health, maximum), in: 0...maximum) { EmptyView() } currentValueLabel: {
                        Text("\(health / 2, format: .number.precision(.fractionLength(0...1))) of \(maximum / 2, format: .number.precision(.fractionLength(0...1))) hearts")
                    }
                    .tint(.red)
                } else {
                    Text("\(health / 2, format: .number.precision(.fractionLength(0...1))) hearts")
                }
            }
            .help("Health recorded when Minecraft last saved this player")
        } else if let maximum, maximum.isFinite, maximum > 0 {
            LabeledContent("Maximum Health", value: String(localized: "\(maximum / 2, format: .number.precision(.fractionLength(0...1))) hearts"))
        }
    }
}

struct PlayerEffectsSection: View {
    let effects: [StatusEffect]

    var body: some View {
        if !effects.isEmpty {
            Section("Active Effects") {
                ForEach(Array(effects.sorted { $0.id < $1.id }.enumerated()), id: \.offset) { _, effect in
                    LabeledContent(TradeText.enchantmentName(effect.id, level: effect.level), value: PlayerEffectText.duration(effect))
                        .monospacedDigit()
                }
            }
            .help("Effects and time remaining when Minecraft last saved this player")
        }
    }
}

nonisolated enum PlayerEffectText {
    static func duration(_ effect: StatusEffect) -> String {
        guard effect.durationTicks != -1 else { return String(localized: "Infinite") }
        let seconds = effect.durationTicks / 20 + (effect.durationTicks % 20 == 0 ? 0 : 1)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
