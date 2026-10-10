import Foundation
import MCWorldKit
import Observation

/// The world's index and the searches over it. The index holds what the search bar, the
/// sidebar's lists and searches, and the map's markers show; it's built in the background when the
/// world opens, a dimension at a time, and again after the game saves.
@Observable
final class SearchModel {
    /// The search bar's text.
    var text = "" {
        didSet { if text != oldValue { selectedHitID = nil } }
    }
    /// The result the map is centered on, highlighted among the result markers.
    var selectedHitID: SearchHit.ID?
    /// Players whose inventories and ender chests are searched too; updated when the game saves them.
    var players: [PlayerInfo] {
        didSet { cachedResults = [:] }
    }
    /// Every dimension read so far. Each appears as soon as it's read; a rebuild replaces each
    /// dimension in place, so what's shown never empties.
    private(set) var index = SearchIndex() {
        didSet {
            cachedResults = [:]
            portals = index.dimensions.mapValues { $0.places.compactMap(\.portal) }
        }
    }
    /// Every Nether portal read so far, by dimension id, for predicting links. Kept rather than
    /// computed: each portal marker asks on every redraw.
    private(set) var portals: [String: [NetherPortal]] = [:]
    /// True until every dimension has been read once.
    private(set) var isIndexing = false

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The search bar's results.
    var results: [SearchHit] { results(for: text) }

    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// Results by query, cleared when the index or players change: saved searches and map pins
    /// ask for the same results on every redraw.
    @ObservationIgnored private var cachedResults: [String: [SearchHit]] = [:]
    private let readers: [RegionReader]
    private let names: PlayerNames
    private let singleplayerUUID: UUID?

    init(readers: [RegionReader], players: [PlayerInfo], names: PlayerNames, singleplayerUUID: UUID?, firstDimension: String?) {
        self.readers = readers
        self.players = players
        self.names = names
        self.singleplayerUUID = singleplayerUUID
        rebuild(firstDimension: firstDimension)
    }

    /// The places matching `query`, most items first.
    func results(for query: String) -> [SearchHit] {
        if let cached = cachedResults[query] { return cached }
        let names = names, singleplayerUUID = singleplayerUUID
        let found = WorldSearch.search(query, in: index, players: players) {
            PlayerPresentation.name(of: $0, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid))
        }
        cachedResults[query] = found
        return found
    }

    /// Reads every dimension again in the background, `firstDimension` (the one shown) first, at
    /// utility priority so drawing the map comes first. Called when the world opens and after the
    /// game saves.
    func rebuild(firstDimension: String?) {
        indexTask?.cancel()
        isIndexing = index.dimensions.isEmpty
        let readers = readers.sorted { ($0.dimension.id == firstDimension ? 0 : 1) < ($1.dimension.id == firstDimension ? 0 : 1) }
        indexTask = Task(priority: .utility) { [weak self] in
            for reader in readers {
                let part = await DimensionIndex.read(reader)
                guard let self, !Task.isCancelled else { return }
                self.index.dimensions[reader.dimension.id] = part
            }
            self?.isIndexing = false
        }
    }

    /// Waits for the index being built, if any.
    func waitForIndex() async {
        await indexTask?.value
    }

    func cancel() {
        indexTask?.cancel()
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
