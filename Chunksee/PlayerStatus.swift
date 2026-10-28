import ChunkseeKit
import SwiftUI

struct PlayerEffectsSection: View {
    let effects: [StatusEffect]
    @Environment(\.gameNames) private var gameNames
    @Environment(\.locale) private var locale

    var body: some View {
        if !effects.isEmpty {
            Section("Active Effects") {
                ForEach(Array(effects.sorted { $0.id < $1.id }.enumerated()), id: \.offset) { _, effect in
                    let name = Text(PlayerEffectText.name(effect, gameNames: gameNames, locale: locale))
                    LabeledContent {
                        Text(PlayerEffectText.duration(effect, locale: locale))
                    } label: {
                        name
                    }
                        .monospacedDigit()
                        // Form's labeled-value style discards an inner Text's accessibility
                        // label. Represent the row with the same native control and full units.
                        .accessibilityRepresentation {
                            LabeledContent {
                                Text(PlayerEffectText.accessibleDuration(effect, locale: locale))
                            } label: {
                                name
                            }
                        }
                }
            }
            .help("Effects and time remaining when Minecraft last saved this player")
        }
    }
}

nonisolated enum PlayerEffectText {
    static func name(_ effect: StatusEffect, gameNames: GameNames, locale: Locale = .current) -> String {
        let base = gameNames.name(effect.id, in: "effect")
        guard effect.level > 1 else { return base }
        return String(localized: "\(base) \(LevelText.numeral(effect.level))", locale: locale)
    }

    static func duration(_ effect: StatusEffect, locale: Locale = .current) -> String {
        guard let saved = savedDuration(effect) else { return String(localized: "Infinite", locale: locale) }
        return saved.formatted(.time(pattern: saved >= .seconds(3600)
                                     ? .hourMinuteSecond(padHourToLength: 1)
                                     : .minuteSecond(padMinuteToLength: 1)).locale(locale))
    }

    static func accessibleDuration(_ effect: StatusEffect, locale: Locale = .current) -> String {
        guard let saved = savedDuration(effect) else { return String(localized: "Infinite", locale: locale) }
        return saved.formatted(GameDuration.units().locale(locale))
    }

    private static func savedDuration(_ effect: StatusEffect) -> Duration? {
        guard effect.durationTicks != -1 else { return nil }
        return GameDuration.fromTicks(effect.durationTicks, roundingUp: true)
    }
}
