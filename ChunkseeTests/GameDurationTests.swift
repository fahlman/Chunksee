import ChunkseeKit
import Foundation
import Testing
@testable import Chunksee

@Suite struct GameDurationTests {
    private let english = Locale(identifier: "en_US")

    @Test func decodedWorldAgeAndPlayerStatisticsShareElapsedUnits() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let level = NBT.compound(["Data": .compound([
            "LevelName": .string("Elapsed time"), "DataVersion": .int(5023), "Time": .long(36_000),
        ])])
        try Data(Compression.deflate(level.serialized(), gzip: true)).write(to: url.appendingPathComponent("level.dat"))
        let age = try #require(World(contentsOf: url).level.time)
        let modern = try PlayerStatistics(json: Data(#"{"stats":{"minecraft:custom":{"minecraft:play_time":36000}}}"#.utf8))
        let older = try PlayerStatistics(json: Data(#"{"stats":{"minecraft:custom":{"minecraft:play_one_minute":36000}}}"#.utf8))
        let legacy = try PlayerStatistics(json: Data(#"{"stat.playOneMinute":36000}"#.utf8))
        for ticks in [age, try #require(modern.playTime), try #require(older.playTime), try #require(legacy.playTime)] {
            #expect(GameDuration.elapsed(ticks, locale: english) == "30 minutes")
        }
    }

    @Test func elapsedTimeUsesCompletedSecondsAndNativePlurals() {
        let cases: [(Int, String)] = [
            (0, "0 seconds"), (1, "0 seconds"), (19, "0 seconds"), (20, "1 second"),
            (1199, "59 seconds"), (1200, "1 minute"), (1680, "1 minute, 24 seconds"),
            (71999, "59 minutes, 59 seconds"), (72000, "1 hour"),
            (73220, "1 hour, 1 minute, 1 second"), (88_848_000, "1,234 hours"),
        ]
        for (ticks, text) in cases { #expect(GameDuration.elapsed(ticks, locale: english) == text) }
        #expect(GameDuration.elapsed(-1, locale: english) == nil)
        #expect(GameDuration.elapsed(Int.min, locale: english) == nil)
        #expect(PlayerEffectText.duration(.init(id: "minecraft:speed", amplifier: 0, durationTicks: 1), locale: english) == "0:01")
        #expect(PlayerEffectText.duration(.init(id: "minecraft:speed", amplifier: 0, durationTicks: -1), locale: english) == "Infinite")
    }

    @Test func elapsedUnitsFollowLocaleWithoutChangingTheDayClock() {
        let french = GameDuration.elapsed(73220, locale: Locale(identifier: "fr_FR"))?
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        #expect(french == "1 heure, 1 minute et 1 seconde")
        #expect(GameDuration.elapsed(1680, locale: Locale(identifier: "ar_EG")) == "دقيقة و٢٤ ثانية")
        #expect(WorldDetails.clockTime(ofDayTicks: 0) == (6, 0))
        #expect(WorldDetails.clockTime(ofDayTicks: 18_000) == (0, 0))
    }
}
