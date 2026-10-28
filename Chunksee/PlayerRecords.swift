import Foundation
import ChunkseeKit
import Observation
import SwiftUI

/// A player's statistics and advancements, read from their JSON files.
nonisolated struct PlayerRecords: Sendable {
    var statistics: PlayerStatistics?
    var advancements: [AdvancementProgress] = []

    /// Reads both files off the main actor. Statistics from before 1.7.6 are stored under the
    /// player's name, so `name` is tried when there's no file for the UUID.
    @concurrent
    static func load(from world: World, uuid: UUID, name: String?) async -> PlayerRecords {
        var records = PlayerRecords()
        guard !Task.isCancelled else { return records }
        records.statistics = (try? world.statistics(for: uuid)) ?? name.flatMap { try? world.statistics(forName: $0) }
        guard !Task.isCancelled else { return records }
        records.advancements = ((try? world.advancements(for: uuid)) ?? nil) ?? []
        return records
    }

    /// Completed advancements, newest first; recipe unlocks aren't advancements in the game.
    var completedAdvancements: [AdvancementProgress] {
        advancements.filter { $0.isDone && !$0.isRecipe }.sorted { ($0.completed ?? .distantPast) > ($1.completed ?? .distantPast) }
    }

    /// The largest counts in a category, e.g. the most-mined blocks.
    func top(_ category: String, count: Int = 5) -> [StatisticRow] {
        (statistics?.values[category] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count).map { row(id: $0.key, value: $0.value, in: category) }
    }

    /// The inspector keeps its longest-first travel summary and 100-meter cutoff.
    var distances: [StatisticRow] {
        (statistics?.distances ?? [:]).filter { $0.value >= 10_000 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { row(id: $0.key, value: $0.value, in: "minecraft:custom") }
    }

    var summaryStatistics: [StatisticRow] {
        guard let statistics else { return [] }
        var primary: [StatisticRow] = []
        if let time = statistics.playTime, time >= 0 {
            // The summary has one stable time identity; Kit chooses its saved source value.
            primary.append(row(id: "minecraft:play_time", value: time, in: "minecraft:custom"))
        }
        for id in ["minecraft:mob_kills", "minecraft:deaths"] {
            if let value = statistics.value(id) {
                primary.append(row(id: id, value: value, in: "minecraft:custom"))
            }
        }
        return primary + distances
    }

    static func travelName(_ id: String, gameNames: GameNames) -> String {
        gameNames.name(id, in: "stat")
    }

    static func advancementName(_ id: String, gameNames: GameNames) -> String {
        gameNames.advancement(id)
    }

    /// Every statistic as a row, for the sortable table.
    var rows: [StatisticRow] {
        (statistics?.values ?? [:]).flatMap { category, values in
            values.map { row(id: $0.key, value: $0.value, in: category) }
        }.sorted { ($0.categoryID, $0.statisticID) < ($1.categoryID, $1.statisticID) }
    }

    private func row(id: String, value: Int, in category: String) -> StatisticRow {
        StatisticRow(categoryID: category, statisticID: id, value: value, unit: statistics?.unit(of: id, in: category))
    }
}

/// The inspector's current read. A result must still belong to the selected player and request.
@Observable
final class PlayerRecordsModel {
    private(set) var uuid: UUID?
    private(set) var records: PlayerRecords?
    @ObservationIgnored private var generation = UUID()
    private let work: BackgroundWork.Scope
    private let read: @Sendable (UUID, String?) async -> PlayerRecords

    init(world: World, work: BackgroundWork, read: (@Sendable (UUID, String?) async -> PlayerRecords)? = nil) {
        self.work = work.makeScope()
        self.read = read ?? { await PlayerRecords.load(from: world, uuid: $0, name: $1) }
    }

    func load(_ uuid: UUID, name: String?) async {
        guard !work.isClosed, !Task.isCancelled else { return }
        cancel()
        self.uuid = uuid
        let id = generation, read = read
        guard let task = work.start(priority: nil, operation: { [weak self] in
            let records = await read(uuid, name)
            guard !Task.isCancelled, let self, self.generation == id, self.uuid == uuid else { return }
            self.records = records
        }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    func cancel() {
        generation = UUID()
        work.cancel()
        uuid = nil
        records = nil
    }

    func waitForReads() async {
        await work.waitUntilFinished()
    }

    func close() {
        cancel()
        work.close()
    }
}

nonisolated struct StatisticRow: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let category: String
        let statistic: String
    }

    var id: ID { ID(category: categoryID, statistic: statisticID) }
    var categoryID: String
    var statisticID: String
    var value: Int
    var unit: PlayerStatistics.Unit?

    var category: String {
        categoryID == "minecraft:custom" ? String(localized: "General") : ReadableName.from(categoryID)
    }

    func name(in gameNames: GameNames) -> String {
        switch categoryID {
        case "minecraft:custom": gameNames.name(statisticID, in: "stat")
        case "minecraft:mined": gameNames.name(statisticID, in: "block")
        case "minecraft:killed", "minecraft:killed_by": gameNames.name(statisticID, in: "entity")
        case "minecraft:used", "minecraft:broken", "minecraft:crafted", "minecraft:picked_up", "minecraft:dropped":
            gameNames.item(statisticID)
        default: ReadableName.from(statisticID)
        }
    }

    /// Both surfaces format the same saved value; the reader owns its unit, not its label.
    struct ValueStyle: FormatStyle, Sendable {
        private var locale = Locale.autoupdatingCurrent

        func locale(_ locale: Locale) -> Self {
            var copy = self
            copy.locale = locale
            return copy
        }

        func format(_ row: StatisticRow) -> String {
            switch row.unit {
            case .ticks:
                if let elapsed = GameDuration.elapsed(row.value) {
                    return elapsed.formatted(GameDuration.units().locale(locale))
                }
            case .centimeters:
                let centimeters = Double(row.value)
                let length: Measurement<UnitLength>
                switch abs(centimeters) {
                case 100_000...: length = Measurement(value: centimeters / 100_000, unit: .kilometers)
                case 100...: length = Measurement(value: centimeters / 100, unit: .meters)
                default: length = Measurement(value: centimeters, unit: .centimeters)
                }
                return length.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                      numberFormatStyle: .number.precision(.fractionLength(0...2))).locale(locale))
            case .tenthsOfDamagePoint:
                // Ten saved units per damage point, two damage points per displayed heart.
                return CountedText.hearts.locale(locale).format(Double(row.value) / 20)
            case nil:
                break
            }
            return row.value.formatted(.number.locale(locale))
        }
    }
}

/// Statistics and advancements sections of the player inspector.
struct PlayerRecordsSections: View {
    let records: PlayerRecords?
    @Environment(\.gameNames) private var gameNames
    @Binding var showsAllStatistics: Bool

    var body: some View {
        if let records {
            if records.statistics != nil {
                Section("Statistics") {
                    ForEach(records.summaryStatistics) { row in
                        LabeledContent(row.name(in: gameNames)) { Text(row, format: StatisticRow.ValueStyle()).monospacedDigit() }
                    }
                    Button("All Statistics…") { showsAllStatistics = true }
                }
                ranking("Most Mined", records.top("minecraft:mined"))
                ranking("Most Killed", records.top("minecraft:killed"))
            }
            let completed = records.completedAdvancements
            if !completed.isEmpty {
                Section {
                    ForEach(completed.prefix(5), id: \.id) { advancement in
                        LabeledContent(PlayerRecords.advancementName(advancement.id, gameNames: gameNames)) {
                            if let date = advancement.completed { Text(date, format: .dateTime.year().month().day()) }
                        }
                    }
                } header: {
                    Text("Advancements: \(completed.count) completed")
                }
            }
            if records.statistics == nil && records.advancements.isEmpty {
                Section("Statistics") { Text("No statistics recorded").foregroundStyle(.secondary) }
            }
        } else {
            Section("Statistics") {
                ProgressView("Reading player records…").controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func ranking(_ title: LocalizedStringKey, _ entries: [StatisticRow]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { row in
                    LabeledContent(row.name(in: gameNames)) { Text(row, format: StatisticRow.ValueStyle()).monospacedDigit() }
                }
            }
        }
    }
}

/// Every statistic in a sortable table.
struct StatisticsTable: View {
    let rows: [StatisticRow]
    @Environment(\.gameNames) private var gameNames
    @State private var sortOrder = [KeyPathComparator(\NamedRow.value, order: .reverse)]

    nonisolated private struct NamedRow: Identifiable, Sendable {
        let row: StatisticRow
        let name: String
        var id: StatisticRow.ID { row.id }
        var category: String { row.category }
        var value: Int { row.value }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All Statistics").font(.headline).accessibilityAddTraits(.isHeader)
            Table(rows.map { NamedRow(row: $0, name: $0.name(in: gameNames)) }.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Category", value: \.category)
                TableColumn("Statistic", value: \.name)
                TableColumn("Value", value: \.value) { Text($0.row, format: StatisticRow.ValueStyle()).monospacedDigit() }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .onExitCommand { dismiss() }
    }
}
