import Foundation
import MCWorldKit
import Observation

/// Immutable input for one background query pass. Names are captured with the index and players.
nonisolated struct SearchRequest: Sendable {
    var queries: [String]
    var index: SearchIndex
    var players: [PlayerInfo]
    var playerNames: [UUID: String]
}

/// The world index and published query results. Views read snapshots; they never scan a world.
@Observable
final class SearchModel {
    var text = "" {
        didSet {
            if text != oldValue { selectedHitID = nil; updateQueries() }
        }
    }
    var selectedHitID: SearchHit.ID?
    var players: [PlayerInfo] {
        didSet { revision += 1; updateQueries() }
    }
    private(set) var index = SearchIndex() {
        didSet {
            revision += 1
            portals = index.dimensions.mapValues { $0.places.compactMap(\.portal) }
            updateQueries()
        }
    }
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var isIndexing = false
    private(set) var isSearching = false
    private var queryResults: [String: [SearchHit]] = [:]
    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
    var results: [SearchHit] { results(for: text) }

    private let readers: [RegionReader]
    private let names: PlayerNames
    private let singleplayerUUID: UUID?
    private let savedSearches: SavedSearches
    private let execute: @Sendable (SearchRequest) async -> [String: [SearchHit]]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var queryGeneration = UUID()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var isClosed = false

    private struct Inputs: Equatable {
        var queries: [String]
        var names: [UUID: String]
        var revision: Int
    }

    init(readers: [RegionReader], players: [PlayerInfo], names: PlayerNames, singleplayerUUID: UUID?,
         firstDimension: String?, savedSearches: SavedSearches,
         execute: @escaping @Sendable (SearchRequest) async -> [String: [SearchHit]] = WorldSearch.execute) {
        self.readers = readers
        self.players = players
        self.names = names
        self.singleplayerUUID = singleplayerUUID
        self.savedSearches = savedSearches
        self.execute = execute
        observeSources()
        rebuild(firstDimension: firstDimension)
        updateQueries()
    }

    func results(for query: String) -> [SearchHit] { queryResults[query] ?? [] }

    /// Shared names and saved searches can change from another window or Settings.
    private func observeSources() {
        withObservationTracking {
            _ = names.local
            _ = names.online
            _ = savedSearches.all
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
        let queries = Array(Set(([text] + savedSearches.all.map(\.query)).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })).sorted()
        let playerNames = Dictionary(uniqueKeysWithValues: players.map {
            ($0.uuid, PlayerPresentation.name(of: $0, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid)))
        })
        let next = Inputs(queries: queries, names: playerNames, revision: revision)
        guard next != inputs else { return }
        inputs = next
        queryTask?.cancel()
        queryGeneration = UUID()
        queryResults = [:]
        isSearching = !queries.isEmpty
        guard !queries.isEmpty else { queryTask = nil; return }
        let id = queryGeneration, execute = execute
        let request = SearchRequest(queries: queries, index: index, players: players, playerNames: playerNames)
        let task = Task(priority: .userInitiated) { [weak self] in
            defer { self?.tasks[id] = nil }
            let found = await execute(request)
            guard !Task.isCancelled, let self, !self.isClosed, self.queryGeneration == id else { return }
            self.queryResults = found
            self.isSearching = false
        }
        queryTask = task
        tasks[id] = task
    }

    /// Reads dimensions at utility priority, replacing each in place after it finishes.
    func rebuild(firstDimension: String?) {
        guard !isClosed else { return }
        indexTask?.cancel()
        isIndexing = index.dimensions.isEmpty
        let readers = readers.sorted { ($0.dimension.id == firstDimension ? 0 : 1) < ($1.dimension.id == firstDimension ? 0 : 1) }
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            defer { self?.tasks[id] = nil }
            for reader in readers {
                guard !Task.isCancelled else { return }
                let part = await DimensionIndex.read(reader)
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                self.index.dimensions[reader.dimension.id] = part
            }
            self?.isIndexing = false
        }
        indexTask = task
        tasks[id] = task
    }

    func waitForIndex() async { await indexTask?.value }

    /// Waits for the query snapshot actually consumed by the UI, including a changed shared source.
    func waitForSearch() async {
        updateQueries()
        while let task = queryTask {
            let id = queryGeneration
            await task.value
            updateQueries()
            if id == queryGeneration { return }
        }
    }

    func cancel() {
        isClosed = true
        queryGeneration = UUID()
        tasks.values.forEach { $0.cancel() }
        isSearching = false
        isIndexing = false
    }

    func waitForTasks() async {
        for task in tasks.values { await task.value }
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
