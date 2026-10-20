import Foundation
import ChunkseeKit
import SwiftUI

/// World-wide settings and state beyond `level.dat`'s basics, read once when the world opens.
nonisolated struct WorldDetails: Sendable {
    /// Verified dimension-type metadata, keyed by the saved dimension ID.
    var dimensionTypes: [String: DimensionType] = [:]
    var seed: Int64?
    /// Saved identifiers remain the identity; readable names are presentation only.
    var gameRules: [String: GameRuleValue] = [:]
    var weather: Weather?
    var dayTime: Int?
    /// World borders by dimension id.
    var borders: [String: WorldBorder] = [:]
    var dragonFight: EnderDragonFight?
    var wanderingTrader: WanderingTraderTimer?
    /// Maps made in the game that have something drawn, in a recognized dimension.
    var maps: [MapItem] = []

    var gameRuleRows: [(id: String, name: String, value: GameRuleValue)] {
        gameRules.map { (id: $0.key, name: Self.readableRule($0.key), value: $0.value) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    var wanderingTradersAreOff: Bool {
        GameRule.wanderingTraderSpawning.value(in: gameRules) == .bool(false)
    }

    static func traderDelayDescription(_ ticks: Int, locale: Locale = .current) -> String {
        let delay = GameDuration.fromTicks(ticks)
        guard delay >= .seconds(60) else { return String(localized: "Within a minute of play", locale: locale) }
        let minutes = GameDuration.units(delay, allowed: [.minutes], locale: locale)
        return String(localized: "In about \(minutes) of play", locale: locale)
    }

    /// Reads every file it can; one that's missing or unreadable leaves its field empty.
    static func read(_ world: World) -> WorldDetails {
        var details = WorldDetails()
        details.dimensionTypes = (try? world.dimensionTypes()) ?? [:]
        details.seed = try? world.seed()
        details.gameRules = (try? world.gameRules()) ?? [:]
        details.weather = try? world.weather()
        details.dayTime = try? world.dayTime()
        for dimension in world.dimensions() {
            if let border = try? world.worldBorder(of: dimension) { details.borders[dimension.id] = border }
        }
        details.dragonFight = try? world.enderDragonFight()
        details.wanderingTrader = try? world.wanderingTrader()
        details.maps = world.mapItems().filter { !$0.isBlank && $0.dimension != nil }
        return details
    }

    /// `minecraft:keep_inventory` and the older `keepInventory` both become "Keep Inventory".
    static func readableRule(_ id: String) -> String {
        let base = ReadableName.identifierPath(id)
        if base.contains("_") { return ReadableName.from(base) }
        var words: [String] = []
        for character in base {
            if character.isUppercase || words.isEmpty { words.append(String(character)) } else { words[words.count - 1].append(character) }
        }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Minecraft's clock starts each day at 6:00 in the morning; 1,000 ticks make an hour.
    static func clockTime(ofDayTicks ticks: Int) -> (hour: Int, minute: Int) {
        let inDay = ((ticks % 24_000) + 24_000) % 24_000
        return ((inDay / 1000 + 6) % 24, inDay % 1000 * 60 / 1000)
    }
}

/// World settings and state in the inspector: version, time, weather, the dragon, borders,
/// mods and game rules.
struct WorldInfoView: View {
    let session: WorldSession
    @State private var showsSeed = false
    @Environment(\.locale) private var locale

    private var level: LevelInfo { session.world.level }
    private var details: WorldDetails { session.details }

    var body: some View {
        Form {
            Section {
                if let version = level.versionName { LabeledContent("Minecraft Version", value: version) }
                LabeledContent("Difficulty", value: difficulty)
                if level.allowCommands == true { LabeledContent("Cheats", value: String(localized: "Allowed")) }
                if let spawn = level.spawnPosition {
                    LabeledContent("World Spawn", value: Coordinates.text(CGPoint(x: spawn.x, y: spawn.z), y: spawn.y))
                        .monospacedDigit()
                }
                if let seed = details.seed {
                    LabeledContent("Seed") {
                        if showsSeed {
                            Text(String(seed)).textSelection(.enabled).monospacedDigit()
                        } else {
                            Button("Show") { showsSeed = true }
                                .help("The seed reveals where everything is, which can spoil exploring")
                        }
                    }
                }
            } header: {
                Text(session.presentation.displayName).font(.headline)
            }
            Section("Time and Weather") {
                if let ticks = level.time, let elapsed = GameDuration.elapsed(ticks, locale: locale) {
                    LabeledContent("World Age", value: elapsed)
                        .help("Time the world has been running in the game, at 20 ticks a second")
                }
                if let ticks = details.dayTime {
                    LabeledContent("Day", value: (ticks / 24_000 + 1).formatted())
                    LabeledContent("Time of Day", value: clockTime(ticks))
                }
                if let weather = details.weather {
                    LabeledContent("Weather", value: weather.isThundering ? String(localized: "Thunderstorm")
                                   : weather.isRaining ? String(localized: "Rain") : String(localized: "Clear"))
                }
            }
            if let fight = details.dragonFight {
                Section("The End") {
                    // Until the game has checked the End, its kill flags aren't confirmed either way (ChunkseeKit's rule).
                    LabeledContent("Ender Dragon", value: fight.needsStateScanning ? String(localized: "Not checked yet")
                                   : fight.isDefeated ? String(localized: "Defeated") : String(localized: "Not defeated"))
                        .help(fight.needsStateScanning ? String(localized: "Minecraft checks the fight the next time a player visits the End") : "")
                    LabeledContent("End Gateways", value: String(localized: "\(20 - fight.remainingGateways) of 20 open"))
                        .help("Each time the dragon is defeated, one more gateway to the outer End islands opens")
                }
            }
            if let trader = details.wanderingTrader {
                Section("Wandering Trader") {
                    if details.wanderingTradersAreOff {
                        Text("Turned off by a game rule").foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Next Chance", value: WorldDetails.traderDelayDescription(trader.spawnDelay, locale: locale))
                        LabeledContent("Odds", value: (Double(trader.spawnChance) / 100).formatted(.percent))
                            .help("The odds rise after each attempt that doesn’t bring a trader")
                    }
                }
            }
            Section("World Border") {
                ForEach(session.dimensions, id: \.id) { dimension in
                    LabeledContent(session.presentation.dimensionName(dimension.id), value: borderDescription(details.borders[dimension.id]))
                }
            }
            Section("Mods and Data Packs") {
                LabeledContent("Modded", value: level.wasModded
                               ? String(localized: "Yes (\(level.serverBrands.joined(separator: ", ")))") : String(localized: "No"))
                // One row per pack: a joined list would make the inspector as wide as the list.
                ForEach(level.enabledDataPacks, id: \.self) { pack in
                    LabeledContent(pack, value: String(localized: "On"))
                }
                ForEach(level.disabledDataPacks, id: \.self) { pack in
                    LabeledContent(pack, value: String(localized: "Off"))
                }
            }
            if !details.gameRules.isEmpty {
                Section("Game Rules") {
                    ForEach(details.gameRuleRows, id: \.id) { rule in
                        switch rule.value {
                        case .bool(let on): LabeledContent(rule.name, value: on ? String(localized: "On") : String(localized: "Off"))
                        case .int(let number): LabeledContent(rule.name, value: number.formatted())
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var difficulty: String {
        var text = level.difficulty.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? String(localized: "Unknown")
        if level.isHardcore == true { text = String(localized: "\(text), hardcore") }
        if level.difficultyLocked == true { text = String(localized: "\(text), locked") }
        return text
    }

    private func clockTime(_ ticks: Int) -> String {
        let time = WorldDetails.clockTime(ofDayTicks: ticks)
        let date = Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func borderDescription(_ border: WorldBorder?) -> String {
        guard let border, border.isLimited else { return String(localized: "None") }
        guard let size = Coordinates.block(border.size), size >= 0 else { return String(localized: "Unknown") }
        return String(localized: "\(size.formatted()) blocks wide, centered at \(Coordinates.text(x: border.centerX, z: border.centerZ))")
    }
}
