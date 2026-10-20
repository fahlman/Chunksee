import ChunkseeKit
import SwiftUI

struct PlayerEffectsSection: View {
    let effects: [StatusEffect]
    @Environment(\.locale) private var locale

    var body: some View {
        if !effects.isEmpty {
            Section("Active Effects") {
                ForEach(Array(effects.sorted { $0.id < $1.id }.enumerated()), id: \.offset) { _, effect in
                    let name = Text(effect, format: PlayerEffectText.NameStyle())
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
    static func name(_ effect: StatusEffect, locale: Locale = .current) -> String {
        NameStyle().locale(locale).format(effect)
    }

    nonisolated struct NameStyle: FormatStyle, Sendable {
        private var locale = Locale.autoupdatingCurrent

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ effect: StatusEffect) -> String {
            let base: String
            // Vanilla names that cannot be recovered by making the id readable. Keep modded ids
            // on the ordinary fallback, rather than assigning them a vanilla effect's meaning.
            switch effect.id {
            case "minecraft:unluck": base = String(localized: "Bad Luck", locale: locale)
            case "minecraft:dolphins_grace": base = String(localized: "Dolphin's Grace", locale: locale)
            case "minecraft:hero_of_the_village": base = String(localized: "Hero of the Village", locale: locale)
            case "minecraft:breath_of_the_nautilus": base = String(localized: "Breath of the Nautilus", locale: locale)
            default: base = ReadableName.from(effect.id)
            }
            guard effect.level > 1 else { return base }
            return String(localized: "\(base) \(LevelText.numeral(effect.level))", locale: locale)
        }
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
