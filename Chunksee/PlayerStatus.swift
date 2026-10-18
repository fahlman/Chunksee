import ChunkseeKit
import SwiftUI

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
