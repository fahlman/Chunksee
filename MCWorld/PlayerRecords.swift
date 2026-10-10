import Foundation
import MCWorldKit
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
        records.statistics = (try? world.statistics(for: uuid)) ?? name.flatMap { try? world.statistics(forName: $0) }
        records.advancements = ((try? world.advancements(for: uuid)) ?? nil) ?? []
        return records
    }

    /// Completed advancements, newest first; recipe unlocks aren't advancements in the game.
    var completedAdvancements: [AdvancementProgress] {
        advancements.filter { $0.isDone && !$0.isRecipe }.sorted { ($0.completed ?? .distantPast) > ($1.completed ?? .distantPast) }
    }

    /// The largest counts in a category, e.g. the most-mined blocks.
    func top(_ category: String, count: Int = 5) -> [(name: String, value: Int)] {
        (statistics?.values[category] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count).map { (ReadableName.from($0.key), $0.value) }
    }

    /// Distances by way of travel in kilometers, longest first, leaving out ones under 100 m,
    /// which would show as 0 km.
    var distances: [(name: String, kilometers: Double)] {
        (statistics?.distances ?? [:]).filter { $0.value >= 10_000 }
            .map { (Self.travelName($0.key), Double($0.value) / 100_000) }
            .sorted { $0.kilometers > $1.kilometers }
    }

    /// `minecraft:walk_one_cm` → "Walk", `minecraft:aviate_one_cm` → "Elytra".
    static func travelName(_ id: String) -> String {
        let base = (id.split(separator: ":").last.map(String.init) ?? id).replacingOccurrences(of: "_one_cm", with: "")
        let names = ["aviate": String(localized: "Elytra"), "walk_on_water": String(localized: "Walk on Water"),
                     "walk_under_water": String(localized: "Walk Under Water")]
        return names[base] ?? ReadableName.from(base)
    }

    /// `minecraft:story/mine_diamond` → "Mine Diamond".
    static func advancementName(_ id: String) -> String {
        ReadableName.from(String(id.split(separator: "/").last ?? Substring(id)))
    }

    /// Every statistic as a row, for the sortable table.
    var rows: [StatisticRow] {
        (statistics?.values ?? [:]).flatMap { category, values in
            // The game shows `minecraft:custom` as "General".
            let name = category == "minecraft:custom" ? String(localized: "General") : ReadableName.from(category)
            return values.map { StatisticRow(category: name, name: ReadableName.from($0.key), value: $0.value) }
        }
    }
}

nonisolated struct StatisticRow: Identifiable, Sendable {
    var id: String { category + "/" + name }
    var category: String
    var name: String
    var value: Int
}

/// Statistics and advancements sections of the player inspector.
struct PlayerRecordsSections: View {
    let records: PlayerRecords?
    @Binding var showsAllStatistics: Bool

    var body: some View {
        if let records {
            if let stats = records.statistics {
                Section("Statistics") {
                    if let ticks = stats.playTime {
                        LabeledContent("Time Played", value: String(localized: "\(ticks / 72_000) hours"))
                    }
                    if let kills = stats.value("minecraft:mob_kills") { LabeledContent("Mobs Killed", value: kills.formatted()) }
                    if let deaths = stats.value("minecraft:deaths") { LabeledContent("Deaths", value: deaths.formatted()) }
                    ForEach(records.distances, id: \.name) { travel in
                        LabeledContent(travel.name, value: String(localized: "\(travel.kilometers, format: .number.precision(.fractionLength(0...1))) km"))
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
                        LabeledContent(PlayerRecords.advancementName(advancement.id)) {
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
            Section("Statistics") { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func ranking(_ title: LocalizedStringKey, _ entries: [(name: String, value: Int)]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries, id: \.name) { LabeledContent($0.name, value: $0.value.formatted()) }
            }
        }
    }
}

/// Every statistic in a sortable table.
struct StatisticsTable: View {
    let rows: [StatisticRow]
    @State private var sortOrder = [KeyPathComparator(\StatisticRow.value, order: .reverse)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Category", value: \.category)
            TableColumn("Statistic", value: \.name)
            TableColumn("Count", value: \.value) { Text($0.value, format: .number).monospacedDigit() }
        }
        .frame(minWidth: 520, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
