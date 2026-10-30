import Foundation
import ChunkseeKit
import Observation

/// Immutable input for one background query pass. Names are captured with the index and players.
nonisolated struct SearchRequest: Sendable {
    var queries: [String]
    var index: SearchIndex
    var players: [PlayerInfo]
    var playerNames: [UUID: PlayerPresentation.Name]
    var gameNames: GameNames
}

/// Per-window controls over the world's published search results. Views never scan a world.
@Observable
final class SearchModel {
    let queryStore: WorldQueryStore
    private let handle: WorldQueryStore.Handle
    var text: String {
        get { handle.text }
        set { handle.text = newValue }
    }
    var indexStore: WorldIndexStore { queryStore.index }
    var playerRoster: any PlayerSnapshotSource { indexStore.playerRoster }
    var playerSnapshot: PlayerSnapshot { indexStore.snapshot.players }
    var players: [PlayerInfo] { playerSnapshot.players }
    var index: SearchIndex { indexStore.snapshot.index }
    var portals: [String: [NetherPortal]] { indexStore.portals }
    var isIndexing: Bool { indexStore.isIndexing }
    var isSearching: Bool { handle.isSearching }
    var isActive: Bool { handle.isActive }
    var results: [SearchHit] { handle.results }
    private var savedSearches: SavedSearches { queryStore.savedSearches }

    init(queryStore: WorldQueryStore) {
        self.queryStore = queryStore
        handle = queryStore.acquire()
    }

    func results(for query: String) -> [SearchHit] {
        guard !handle.isClosed else { return [] }
        return query == text ? results : queryStore.results(for: query)
    }

    /// The sidebar, map pins and click resolver share this row limit and dimension predicate.
    func listedHits(for query: String, where belongsToDimension: (String?) -> Bool) -> (rows: ArraySlice<SearchHit>, total: Int) {
        let hits = results(for: query).filter { belongsToDimension($0.dimension) }
        return (hits.prefix(200), hits.count)
    }

    var visibleSearchQueries: [String] {
        (isActive ? [text] : []) + savedSearches.all.filter(\.isShown).map(\.query)
    }

    func pinnedHits(where belongsToDimension: (String?) -> Bool) -> [SearchHit] {
        var seen = Set<SearchHit.ID>()
        return visibleSearchQueries.flatMap { listedHits(for: $0, where: belongsToDimension).rows }
            .filter { seen.insert($0.id).inserted }
    }

    var canSaveSearch: Bool {
        let query = text.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && !savedSearches.contains(query)
    }

    /// Saves the search bar's query to the sidebar.
    func saveSearch() {
        savedSearches.add(text)
    }

    /// Reads dimensions at utility priority, replacing each in place after it finishes.
    func rebuild(firstDimension: String?) {
        if !handle.isClosed { indexStore.rebuild(firstDimension: firstDimension) }
    }

    func waitForIndex() async { await indexStore.waitForIndex() }
    func waitForSearch() async { await handle.waitForSearch() }
    func cancel() { handle.close() }
    func waitForTasks() async { await handle.waitForTasks() }
}

/// Searches kept in the sidebar, across worlds, each shown on the map or not.
@Observable
final class SavedSearches {
    struct Search: Codable, Identifiable, Equatable {
        var id = UUID()
        var query: String
        var isShown = true
    }

    private(set) var all: [Search] {
        didSet { if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) } }
    }

    private let defaults: UserDefaults
    private static let key = "savedSearches"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        all = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Search].self, from: $0) } ?? []
    }

    func contains(_ query: String) -> Bool { all.contains { $0.query == query } }

    /// Saves a search, shown on the map, unless it's saved already.
    func add(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !contains(query) else { return }
        all.append(Search(query: query))
    }

    func remove(_ id: Search.ID) {
        all.removeAll { $0.id == id }
    }

    func setShown(_ id: Search.ID, _ isShown: Bool) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].isShown = isShown
    }
}
