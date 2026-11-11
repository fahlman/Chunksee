import ChunkseeKit
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct PlayerEffectPresentationTests {
    private let english = Locale(identifier: "en_US")

    @Test func decodedEffectsUseTheirOwnNamesAndTheGamesSuffixRange() async throws {
        let names = try await GameNameFixture.names()
        let entries: [(String, String)] = [
            ("minecraft:unluck", "Bad Luck"), ("minecraft:dolphins_grace", "Dolphin’s Grace"),
            ("minecraft:hero_of_the_village", "Hero of the Village"),
            ("minecraft:breath_of_the_nautilus", "Breath of the Nautilus"),
            ("minecraft:strength", "Strength"), ("example:unluck", "Unluck"),
        ]
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "active_effects": .list(entries.map { id, _ in
                .compound(["id": .string(id), "amplifier": .byte(0), "duration": .int(1680)])
            } + [.compound(["id": .string("minecraft:resistance"), "amplifier": .byte(-1), "duration": .int(-1)])]),
        ]))
        #expect(player.activeEffects.map { names.effect($0, locale: english) }
                == entries.map(\.1) + ["Resistance"])
        for locale in ["en_US", "fr_FR", "ar_EG"].map(Locale.init(identifier:)) {
            #expect(player.activeEffects.map { names.effect($0, locale: locale) } == entries.map(\.1) + ["Resistance"])
        }
        #expect(player.activeEffects.last?.amplifier == 255 && player.activeEffects.last?.level == 256)
        let legacy = PlayerInfo(uuid: UUID(), nbt: .compound([
            "ActiveEffects": .list([.compound(["Id": .byte(27), "Amplifier": .byte(1), "Duration": .int(1680)])]),
        ]))
        #expect(names.effect(try #require(legacy.activeEffects.first), locale: english) == "Bad Luck II")
        #expect(GameNames.unavailable.enchantmentName("minecraft:sharpness", level: 5) == "Sharpness V")
        #expect(GameNames.unavailable.enchantmentName("minecraft:mending", level: 1) == "Mending I")
    }

    @Test func savedAmplifiersUseTheGamesSuffixBoundsWithoutChangingTheirValues() {
        let amplifiers = [0, 1, 9, 10, 255]
        let player = PlayerInfo(uuid: UUID(), nbt: .compound([
            "active_effects": .list(amplifiers.map { amplifier in
                .compound(["id": .string("minecraft:strength"), "amplifier": .int(Int32(amplifier)), "duration": .int(20)])
            }),
        ]))
        #expect(player.activeEffects.map(\.amplifier) == amplifiers)
        #expect(player.activeEffects.map { GameNames.unavailable.effect($0, locale: english) }
                == ["Strength", "Strength II", "Strength X", "Strength", "Strength"])
    }

    @Test func savedClocksRoundAcrossSecondMinuteAndHourBoundaries() throws {
        let cases: [(Int32, String, String)] = [
            (1, "0:01", "1 second"), (19, "0:01", "1 second"), (20, "0:01", "1 second"),
            (21, "0:02", "2 seconds"), (1199, "1:00", "1 minute"), (1200, "1:00", "1 minute"),
            (1201, "1:01", "1 minute, 1 second"), (1680, "1:24", "1 minute, 24 seconds"),
            (71980, "59:59", "59 minutes, 59 seconds"), (71999, "1:00:00", "1 hour"),
            (72000, "1:00:00", "1 hour"), (72001, "1:00:01", "1 hour, 1 second"),
            (-1, "Infinite", "Infinite"),
        ]
        for (ticks, clock, spoken) in cases {
            let player = PlayerInfo(uuid: UUID(), nbt: .compound([
                "active_effects": .list([.compound(["id": .string("minecraft:strength"), "duration": .int(ticks)])]),
            ]))
            let saved = try #require(player.activeEffects.first)
            #expect(PlayerEffectText.duration(saved, locale: english) == clock)
            #expect(PlayerEffectText.accessibleDuration(saved, locale: english) == spoken)
        }
    }

    @Test func clocksAndSpokenUnitsFollowTheRequestedLocale() {
        let effect = StatusEffect(id: "minecraft:strength", amplifier: 0, durationTicks: 1680)
        let french = Locale(identifier: "fr_FR"), arabic = Locale(identifier: "ar_EG")
        #expect(PlayerEffectText.duration(effect, locale: french) == "1:24")
        #expect(PlayerEffectText.accessibleDuration(effect, locale: french)
            .replacingOccurrences(of: "\u{00a0}", with: " ") == "1 minute et 24 secondes")
        #expect(PlayerEffectText.duration(effect, locale: arabic) == "١:٢٤")
        #expect(PlayerEffectText.accessibleDuration(effect, locale: arabic) == "دقيقة و٢٤ ثانية")
        let minute = StatusEffect(id: effect.id, amplifier: 0, durationTicks: 1200)
        #expect(PlayerEffectText.accessibleDuration(minute, locale: french) == "1 minute")
    }
}
