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
    @Environment(\.locale) private var locale

    var body: some View {
        if !effects.isEmpty {
            Section("Active Effects") {
                ForEach(Array(effects.sorted { $0.id < $1.id }.enumerated()), id: \.offset) { _, effect in
                    let name = PlayerEffectText.name(effect, locale: locale)
                    LabeledContent(name, value: PlayerEffectText.duration(effect, locale: locale))
                        .monospacedDigit()
                        // Form's labeled-value style discards an inner Text's accessibility
                        // label. Represent the row with the same native control and full units.
                        .accessibilityRepresentation {
                            LabeledContent(name, value: PlayerEffectText.accessibleDuration(effect, locale: locale))
                        }
                }
            }
            .help("Effects and time remaining when Minecraft last saved this player")
        }
    }
}

nonisolated enum PlayerEffectText {
    static func name(_ effect: StatusEffect, locale: Locale = .current) -> String {
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

    static func duration(_ effect: StatusEffect, locale: Locale = .current) -> String {
        guard let saved = savedDuration(effect) else { return String(localized: "Infinite", locale: locale) }
        return saved.formatted(.time(pattern: saved >= .seconds(3600)
                                     ? .hourMinuteSecond(padHourToLength: 1)
                                     : .minuteSecond(padMinuteToLength: 1)).locale(locale))
    }

    static func accessibleDuration(_ effect: StatusEffect, locale: Locale = .current) -> String {
        guard let saved = savedDuration(effect) else { return String(localized: "Infinite", locale: locale) }
        return saved.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    private static func savedDuration(_ effect: StatusEffect) -> Duration? {
        guard effect.durationTicks != -1 else { return nil }
        // Show the saved snapshot, rounding positive partial seconds up. Divide first so a
        // long saved duration cannot overflow during addition.
        let seconds = effect.durationTicks / 20 + (effect.durationTicks % 20 == 0 ? 0 : 1)
        return .seconds(seconds)
    }
}
