import ChunkseeKit
import Foundation
import SwiftUI

nonisolated enum StorageText {
    static func summary(kinds: Int, containers: Int, locale: Locale = .current) -> String {
        String(localized: "\(kinds) kinds of items in \(containers) containers", locale: locale)
    }
}

/// One kind of item stored in a dimension's containers: how many in all, and in how many
/// containers. Shulker boxes and bundles count with what's inside them.
nonisolated struct StoredItem: Identifiable, Equatable, Sendable {
    /// Item id, e.g. `minecraft:iron_ingot`.
    var id: String
    var name: String
    var count: Int
    var containers: Int

    /// Totals for every item kind, most first.
    static func totals(in containers: [ItemContainer]) -> [StoredItem] {
        var totals: [String: (count: Int, containers: Int)] = [:]
        for container in containers {
            var here: [String: Int] = [:]
            for item in container.items.flatMap(\.allItems) { here[item.id, default: 0] += item.count }
            for (id, count) in here {
                totals[id, default: (0, 0)].count += count
                totals[id, default: (0, 0)].containers += 1
            }
        }
        return totals.map { StoredItem(id: $0.key, name: ReadableName.from($0.key), count: $0.value.count, containers: $0.value.containers) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

/// The inspector's storage summary for the selected dimension. Choosing an item searches for it,
/// so its containers show in the sidebar and on the map.
struct StorageView: View {
    static let symbol = "shippingbox"
    let session: WorldSession
    @Environment(\.locale) private var locale
    @State private var sortOrder = [KeyPathComparator(\StoredItem.count, order: .reverse)]
    @State private var selection: StoredItem.ID?

    var body: some View {
        let items = session.presentation.selectedIndex.storage
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeading(title: Text("Storage"), symbol: Self.symbol)
            if session.search.isIndexing && items.isEmpty {
                ProgressView("Reading containers…").controlSize(.small)
            } else if items.isEmpty {
                Text("Nothing is stored in this dimension’s containers.").foregroundStyle(.secondary)
            } else {
                Text(StorageText.summary(kinds: items.count, containers: session.presentation.selectedIndex.containers.count, locale: locale))
                    .font(.callout).foregroundStyle(.secondary)
                Table(items.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Item", value: \.name)
                    TableColumn("Count", value: \.count) { Text($0.count, format: .number).monospacedDigit() }
                        .width(min: 50, ideal: 70)
                    TableColumn("Containers", value: \.containers) { Text($0.containers, format: .number).monospacedDigit() }
                        .width(min: 50, ideal: 80)
                }
                .help("Choose an item to find where it’s stored")
            }
        }
        .padding()
        .onChange(of: selection) {
            guard let id = selection, let item = items.first(where: { $0.id == id }) else { return }
            session.search.text = item.name
        }
    }
}
