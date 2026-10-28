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

/// The world index and published query results. Views read snapshots; they never scan a world.
@Observable
final class SearchModel {
    var text = "" {
        didSet {
            if text != oldValue { updateQueries() }
        }
    }
    let playerRoster: PlayerRoster
    var playerSnapshot: PlayerSnapshot { indexStore.playerSnapshot }
    var players: [PlayerInfo] { playerSnapshot.players }
    var index: SearchIndex { indexStore.index }
    var portals: [String: [NetherPortal]] { indexStore.portals }
    var isIndexing: Bool { indexStore.isIndexing }
    private(set) var isSearching = false
    private var queryResults: [String: [SearchHit]] = [:]
    private var displayedQuery = ""
    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
    var results: [SearchHit] {
        isActive && sources?.gameNamesID == readGameNames().identity ? queryResults[displayedQuery] ?? [] : []
    }

    let indexStore: WorldIndexStore
    private let ownsIndex: Bool
    private let readGameNames: @MainActor () -> GameNames
    private let names: PlayerNames
    private let singleplayerUUID: UUID?
    private let savedSearches: SavedSearches
    private let execute: @Sendable (SearchRequest) async -> [String: [SearchHit]]
    private let work: BackgroundWork.Scope
    private struct ActiveQuery {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var activeQueries: [String: ActiveQuery] = [:]
    @ObservationIgnored private var completedQueries: Set<String> = []
    @ObservationIgnored private var sourceGeneration = UUID()
    @ObservationIgnored private var sources: SearchSources?
    private var isClosed: Bool { work.isClosed }

    init(readers: [RegionReader], work: BackgroundWork, playerRoster: PlayerRoster, names: PlayerNames, singleplayerUUID: UUID?,
         firstDimension: String?, savedSearches: SavedSearches,
         execute: @escaping @Sendable (SearchRequest) async -> [String: [SearchHit]] = WorldSearch.execute,
         indexStore: WorldIndexStore? = nil, gameNames: @escaping @MainActor () -> GameNames) {
        self.work = work.makeScope()
        self.ownsIndex = indexStore == nil
        self.indexStore = indexStore ?? WorldIndexStore(readers: readers, work: work, firstDimension: firstDimension, playerRoster: playerRoster)
        self.playerRoster = playerRoster
        precondition(self.indexStore.playerRoster === playerRoster)
        readGameNames = gameNames
        self.names = names
        self.singleplayerUUID = singleplayerUUID
        self.savedSearches = savedSearches
        self.execute = execute
        observeSources()
        updateQueries()
    }

    func results(for query: String) -> [SearchHit] {
        guard sources?.gameNamesID == readGameNames().identity else { return [] }
        return query == text ? results : queryResults[query] ?? []
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

    /// Shared names and saved searches can change from another window or Settings.
    private func observeSources() {
        withObservationTracking {
            _ = readGameNames().identity
            _ = names.local
            _ = names.online
            _ = savedSearches.all
            _ = indexStore.revision
            _ = playerRoster.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.observeSources()
                self.updateQueries()
            }
        }
    }

    private func updateQueries() {
        guard !isClosed, playerSnapshot === playerRoster.snapshot else { return }
        let saved = Set(savedSearches.all.map(\.query))
        let shared = indexStore.savedQueries
        shared.keep(saved)
        let queries = Set(([text] + Array(saved)).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        let playerNames = Dictionary(uniqueKeysWithValues: players.map {
            ($0.uuid, PlayerPresentation.label(of: $0, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid)))
        })
        let gameNames = readGameNames()
        let next = SearchSources(names: playerNames, playerSnapshot: playerSnapshot, indexRevision: indexStore.revision,
                                 gameNamesID: gameNames.identity)
        if next != sources {
            if next.gameNamesID != sources?.gameNamesID { queryResults = [:] }
            sources = next
            sourceGeneration = UUID()
            for query in activeQueries.values { cancelQuery(query) }
            activeQueries = [:]
            completedQueries = []
        }
        for (query, active) in activeQueries where !queries.contains(query) {
            cancelQuery(active)
            activeQueries[query] = nil
        }
        completedQueries.formIntersection(queries)
        if !isActive { displayedQuery = "" }
        else if completedQueries.contains(text) { displayedQuery = text }
        pruneResults(keeping: queries)

        // Editing the current query doesn't invalidate completed or pending saved searches.
        for query in queries.sorted() where !completedQueries.contains(query) && activeQueries[query] == nil {
            let id = UUID(), generation = sourceGeneration, execute = execute
            let request = SearchRequest(queries: [query], index: index, players: players, playerNames: playerNames, gameNames: gameNames)
            let isSaved = saved.contains(query)
            guard let task = work.start(priority: .userInitiated, operation: { [weak self] in
                defer {
                    shared.release(id)
                    if let self, self.isClosed, self.activeQueries[query]?.id == id {
                        self.activeQueries[query] = nil
                        self.isSearching = !self.activeQueries.isEmpty
                    }
                }
                let found: [String: [SearchHit]]?
                if isSaved {
                    found = await shared.results(for: request, sources: next, waiter: id, execute: execute)
                } else {
                    found = await execute(request)
                }
                // Observation schedules the replacement on the main actor; reject an older
                // player publication even if that scheduled callback has not run yet.
                guard !Task.isCancelled, let self, !self.isClosed,
                      self.playerRoster.snapshot === next.playerSnapshot,
                      self.playerSnapshot === next.playerSnapshot,
                      self.readGameNames().identity == next.gameNamesID,
                      self.sourceGeneration == generation, self.activeQueries[query]?.id == id else { return }
                self.activeQueries[query] = nil
                guard let found else { self.isSearching = !self.activeQueries.isEmpty; return }
                self.completedQueries.insert(query)
                self.queryResults[query] = found[query] ?? []
                if query == self.text { self.displayedQuery = query }
                self.updateQueries()
            }) else { return }
            activeQueries[query] = ActiveQuery(id: id, task: task)
        }
        isSearching = !activeQueries.isEmpty
    }

    private func pruneResults(keeping queries: Set<String>) {
        let kept = queries.union(isActive ? [displayedQuery] : [])
        for query in queryResults.keys where !kept.contains(query) {
            queryResults[query] = nil
        }
    }

    /// Reads dimensions at utility priority, replacing each in place after it finishes.
    func rebuild(firstDimension: String?) {
        if !isClosed { indexStore.rebuild(firstDimension: firstDimension) }
    }

    func waitForIndex() async { await indexStore.waitForIndex(); updateQueries() }

    /// Waits for the query snapshot actually consumed by the UI, including a changed shared source.
    func waitForSearch() async {
        await indexStore.waitForProjection()
        updateQueries()
        while !isClosed, !activeQueries.isEmpty {
            let pending = activeQueries.values.map(\.task)
            for task in pending { await task.value }
            await indexStore.waitForProjection()
            updateQueries()
        }
    }

    func cancel() {
        work.close()
        sourceGeneration = UUID()
        for query in activeQueries.values { indexStore.savedQueries.release(query.id) }
        activeQueries = [:]
        isSearching = false
        if ownsIndex { indexStore.cancel() }
    }

    private func cancelQuery(_ query: ActiveQuery) {
        query.task.cancel()
        indexStore.savedQueries.release(query.id)
    }

    func waitForTasks() async {
        await work.waitUntilFinished()
        if ownsIndex { await indexStore.waitForTasks() }
    }
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
