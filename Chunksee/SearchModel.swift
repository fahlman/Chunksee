import Foundation
import ChunkseeKit
import Observation

/// Immutable input for one background query pass. Names are captured with the index and players.
nonisolated struct SearchRequest: Sendable {
    var queries: [String]
    var index: SearchIndex
    var players: [PlayerInfo]
    var playerNames: [UUID: PlayerPresentation.Name]
}

/// The world index and published query results. Views read snapshots; they never scan a world.
@Observable
final class SearchModel {
    var text = "" {
        didSet {
            if text != oldValue { updateQueries() }
        }
    }
    var playerSnapshot: PlayerSnapshot {
        didSet { if playerSnapshot !== oldValue { updateQueries() } }
    }
    var players: [PlayerInfo] { playerSnapshot.players }
    var index: SearchIndex { indexStore.index }
    var portals: [String: [NetherPortal]] { indexStore.portals }
    var isIndexing: Bool { indexStore.isIndexing }
    private(set) var isSearching = false
    private var queryResults: [String: [SearchHit]] = [:]
    private var displayedQuery = ""
    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
    var results: [SearchHit] { isActive ? queryResults[displayedQuery] ?? [] : [] }

    let indexStore: WorldIndexStore
    private let ownsIndex: Bool
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

    init(readers: [RegionReader], work: BackgroundWork, playerSnapshot: PlayerSnapshot, names: PlayerNames, singleplayerUUID: UUID?,
         firstDimension: String?, savedSearches: SavedSearches,
         execute: @escaping @Sendable (SearchRequest) async -> [String: [SearchHit]] = WorldSearch.execute,
         indexStore: WorldIndexStore? = nil) {
        self.work = work.makeScope()
        self.ownsIndex = indexStore == nil
        self.indexStore = indexStore ?? WorldIndexStore(readers: readers, work: work, firstDimension: firstDimension)
        self.playerSnapshot = playerSnapshot
        self.names = names
        self.singleplayerUUID = singleplayerUUID
        self.savedSearches = savedSearches
        self.execute = execute
        observeSources()
        updateQueries()
    }

    func results(for query: String) -> [SearchHit] {
        query == text ? results : queryResults[query] ?? []
    }

    /// Shared names and saved searches can change from another window or Settings.
    private func observeSources() {
        withObservationTracking {
            _ = names.local
            _ = names.online
            _ = savedSearches.all
            _ = indexStore.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.observeSources()
                self.updateQueries()
            }
        }
    }

    private func updateQueries() {
        guard !isClosed else { return }
        let saved = Set(savedSearches.all.map(\.query))
        let shared = indexStore.savedQueries
        shared.keep(saved)
        let queries = Set(([text] + Array(saved)).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        let playerNames = Dictionary(uniqueKeysWithValues: players.map {
            ($0.uuid, PlayerPresentation.label(of: $0, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid)))
        })
        let next = SearchSources(names: playerNames, playerSnapshot: playerSnapshot, indexRevision: indexStore.revision)
        if next != sources {
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
            let request = SearchRequest(queries: [query], index: index, players: players, playerNames: playerNames)
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
                guard !Task.isCancelled, let self, !self.isClosed,
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
        updateQueries()
        while !isClosed, !activeQueries.isEmpty {
            let pending = activeQueries.values.map(\.task)
            for task in pending { await task.value }
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
