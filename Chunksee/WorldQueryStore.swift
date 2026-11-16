import ChunkseeIndex
import ChunkseeKit
import Foundation
import Observation

/// A result keeps its small publication key, not another complete world index.
nonisolated struct SearchSources: Equatable, Sendable {
    let names: [UUID: GameNames.PlayerName]
    let playerSnapshot: PlayerSnapshot
    let indexRevision: Int
    let gameNamesID: GameNames.Identity?
    let singleplayerUUID: UUID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.indexRevision == rhs.indexRevision && lhs.playerSnapshot === rhs.playerSnapshot &&
            lhs.names == rhs.names && lhs.gameNamesID == rhs.gameNamesID && lhs.singleplayerUUID == rhs.singleplayerUUID
    }
}

/// The world owns every query publication. Ordinary saved queries share a producer; block
/// queries share raw counts and keep their captured search point in each window.
@Observable
final class WorldQueryStore {
    typealias Results = [String: [SearchHit]]
    typealias Read = @Sendable (SearchRequest) async -> Results
    let index: WorldIndexStore
    let savedSearches: SavedSearches
    private let blockCounts: WorldBlockCountStore?
    private let names: PlayerNames
    private let gameNames: @MainActor () -> GameNames
    private let singleplayerUUID: @MainActor () -> UUID?
    private let execute: Read
    @ObservationIgnored private var sourceObservation: ModelObservation?
    private let work: BackgroundWork.Scope
    private var shared: [String: Shared] = [:]
    @ObservationIgnored private var windows: [UUID: Window] = [:]
    @ObservationIgnored private var context: Context
    var isClosed: Bool { work.isClosed || index.isClosed }

    nonisolated fileprivate final class Context: Sendable {
        let index: WorldIndexSnapshot
        let currentPlayers: PlayerSnapshot
        let gameNames: GameNames
        let key: SearchSources
        var isReady: Bool { index.players === currentPlayers }

        init(index: WorldIndexSnapshot, currentPlayers: PlayerSnapshot, gameNames: GameNames,
             names: [UUID: GameNames.PlayerName], singleplayerUUID: UUID?) {
            self.index = index
            self.currentPlayers = currentPlayers
            self.gameNames = gameNames
            key = SearchSources(names: names, playerSnapshot: index.players, indexRevision: index.revision,
                                gameNamesID: gameNames.identity, singleplayerUUID: singleplayerUUID)
        }

        func hasSameInputs(as other: Context) -> Bool {
            index === other.index && currentPlayers === other.currentPlayers && key == other.key
        }
    }

    nonisolated fileprivate struct Source: Equatable, Sendable {
        let query: String
        let context: Context
        var blocks: BlockQueryInput? = nil
        var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
        var request: SearchRequest {
            SearchRequest(queries: [query], index: context.index.index, players: context.index.players.players,
                          playerNames: context.key.names, gameNames: context.gameNames, blocks: blocks)
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.query == rhs.query && lhs.context === rhs.context && lhs.blocks == rhs.blocks
        }
    }

    nonisolated fileprivate final class Value: Sendable {
        let query: String
        let sources: SearchSources
        let hits: [SearchHit]
        let blockWorld: WorldReadSource?
        let blockCatalog: NotableBlock.Catalog?
        let blockPoint: BlockSearchPoint?
        init(source: Source, results: Results) {
            query = source.query
            sources = source.context.key
            hits = results[source.query] ?? []
            blockWorld = source.blocks?.counts.world
            blockCatalog = source.blocks?.catalog
            blockPoint = source.blocks?.point
        }
    }

    fileprivate final class Window {
        let loader: RefreshLoader<Source, RefreshInvalidation, Value>
        let work: BackgroundWork.Scope
        var shared: Shared?
        var captureOrigin: @MainActor () -> BlockSearchAnchor? = { nil }
        var origins: [String: BlockSearchAnchor] = [:]
        var savedBlocks: [String: RefreshLoader<Source, RefreshInvalidation, Value>] = [:]
        init(_ loader: RefreshLoader<Source, RefreshInvalidation, Value>, work: BackgroundWork.Scope) {
            self.loader = loader; self.work = work
        }
    }

    fileprivate final class Shared {
        struct Waiter {
            let window: UUID
            let source: Source
            let continuation: CheckedContinuation<Value?, Never>
        }
        let loader: RefreshLoader<Source, RefreshInvalidation, Value>
        var users: Set<UUID> = []
        var waiters: [UUID: Waiter] = [:]
        init(_ loader: RefreshLoader<Source, RefreshInvalidation, Value>) { self.loader = loader }
    }

    init(index: WorldIndexStore, work: BackgroundWork, names: PlayerNames, savedSearches: SavedSearches,
         singleplayerUUID: @escaping @MainActor () -> UUID?, gameNames: @escaping @MainActor () -> GameNames,
         blockCounts: WorldBlockCountStore? = nil,
         execute: @escaping Read = WorldSearch.execute) {
        self.index = index
        self.work = work.makeScope()
        self.names = names
        self.savedSearches = savedSearches
        self.blockCounts = blockCounts
        self.singleplayerUUID = singleplayerUUID
        self.gameNames = gameNames
        self.execute = execute
        context = Self.context(index: index, names: names, singleplayerUUID: singleplayerUUID(), gameNames: gameNames())
        observeSources()
        refresh()
    }

    private static func context(index: WorldIndexStore, names: PlayerNames, singleplayerUUID: UUID?, gameNames: GameNames) -> Context {
        let snapshot = index.snapshot
        let labels = Dictionary(uniqueKeysWithValues: snapshot.players.players.map {
            ($0.uuid, GameNames.PlayerName(playerID: $0.uuid, singleplayerUUID: singleplayerUUID, knownName: names.name(for: $0.uuid)))
        })
        return Context(index: snapshot, currentPlayers: index.playerRoster.snapshot, gameNames: gameNames,
                       names: labels, singleplayerUUID: singleplayerUUID)
    }

    private func loader(source: Source, scope: BackgroundWork.Scope? = nil,
                        read: @escaping @Sendable (Source) async throws -> Value) -> RefreshLoader<Source, RefreshInvalidation, Value> {
        RefreshLoader(progressRead: { source, _, _, _ in .complete(try await read(source)) },
            scope: scope ?? work.makeScope(), priority: .userInitiated, whenInactive: .cancel, source: source,
            firstRequest: .refresh, merge: { _, _ in .refresh }, retainingValue: { previous, _, next in
                guard next.isActive, previous.sources.gameNamesID == next.context.key.gameNamesID,
                      previous.sources.singleplayerUUID == next.context.key.singleplayerUUID,
                      previous.blockWorld == next.blocks?.counts.world,
                      previous.blockCatalog == next.blocks?.catalog,
                      previous.blockPoint == next.blocks?.point else { return nil }
                return previous
            })
    }

    func acquire() -> Handle {
        let windowID = UUID()
        let windowWork = work.makeScope()
        let loader = loader(source: Source(query: "", context: context), scope: windowWork.makeScope()) { [weak self] source in
            guard let self else { throw CancellationError() }
            return try await self.readWindow(windowID, source: source)
        }
        let window = Window(loader, work: windowWork)
        if isClosed { loader.close(); windowWork.close() } else { windows[windowID] = window }
        return Handle(id: windowID, window: window, owner: self)
    }

    private func readWindow(_ id: UUID, source: Source) async throws -> Value {
        guard !isClosed, !Task.isCancelled, let window = windows[id], window.loader.source == source,
              source.context.isReady else { throw CancellationError() }
        if let entry = window.shared {
            guard let value = await wait(for: entry, window: id, source: source) else { throw CancellationError() }
            return value
        }
        let found = await execute(source.request)
        try Task.checkCancellation()
        return Value(source: source, results: found)
    }

    private func sharedEntry(for query: String) -> Shared {
        if let existing = shared[query] { return existing }
        let execute = execute, source = Source(query: query, context: context)
        let loader = loader(source: source) { [weak self] source in
            let found = await execute(source.request)
            if Task.isCancelled {
                await self?.cancelWaiters(query: source.query, source: source)
                throw CancellationError()
            }
            return Value(source: source, results: found)
        }
        // Saving a completed typed query keeps its pins immediately. A window may still
        // display its previous query while a new one loads, so match the value's query too.
        if context.isReady {
            for window in windows.values where window.loader.source == source {
                guard let value = window.loader.value, value.query == query,
                      value.sources == context.key else { continue }
                loader.replace(source: source, value: value)
                break
            }
        }
        let entry = Shared(loader)
        loader.published = { [weak self, weak entry] _, publication in
            guard let self, let entry, !self.isClosed, let value = publication.value,
                  value.sources == publication.source.context.key else { return }
            self.finishWaiters(in: entry, value: value)
        }
        shared[query] = entry
        return entry
    }

    private func update(_ entry: Shared, query: String) {
        guard !isClosed, shared[query] === entry else { return }
        let source = Source(query: query, context: context)
        for (id, waiter) in entry.waiters where waiter.source != source { release(id, from: entry) }
        let needed = savedSearches.contains(query) || !entry.users.isEmpty || !entry.waiters.isEmpty
        if !needed {
            shared[query] = nil
            entry.loader.close()
        } else {
            entry.loader.request(source: source, isEnabled: source.context.isReady, reread: false)
        }
    }

    private func update(_ window: Window, id: UUID, query: String) {
        guard !isClosed, windows[id] === window else { return }
        if query != window.loader.source.query, SearchQuery(query).filter == .block {
            window.origins[query] = window.captureOrigin()
        }
        let source = source(for: query, window: window)
        if source != window.loader.source {
            let previous = window.shared
            previous?.users.remove(id)
            window.shared = savedSearches.contains(query) && SearchQuery(query).filter != .block ? sharedEntry(for: query) : nil
            window.shared?.users.insert(id)
            // Establish the new lease synchronously: removing a saved query before this
            // window's task starts must still let the already requested query finish.
            if let previous { update(previous, query: previous.loader.source.query) }
        }
        if let shared = window.shared {
            update(shared, query: query)
            // A completed saved result is already ready to display. Switching back to it
            // must not briefly show the previous typed query while another waiter starts.
            if source.context.isReady, shared.loader.source == source,
               let value = shared.loader.value, value.sources == source.context.key {
                if window.loader.source != source || window.loader.value !== value {
                    window.loader.replace(source: source, value: value)
                }
                return
            }
        }
        window.loader.request(source: source, isEnabled: source.isActive && source.context.isReady, reread: false)
    }

    private func source(for query: String, window: Window) -> Source {
        guard SearchQuery(query).filter == .block, let blockCounts else { return Source(query: query, context: context) }
        if window.origins[query] == nil { window.origins[query] = window.captureOrigin() }
        window.origins[query]?.update(players: context.currentPlayers.players)
        let input = window.origins[query].map {
            BlockQueryInput(counts: blockCounts.snapshot, catalog: blockCounts.catalog, point: $0.point)
        }
        return Source(query: query, context: context, blocks: input)
    }

    private func updateSavedBlocks(_ window: Window) {
        let wanted = Set(savedSearches.all.filter { $0.isShown && SearchQuery($0.query).filter == .block }.map(\.query))
        for (query, loader) in window.savedBlocks where !wanted.contains(query) {
            loader.close()
            window.savedBlocks[query] = nil
        }
        for query in wanted {
            let source = source(for: query, window: window)
            if window.savedBlocks[query] == nil {
                let execute = execute
                window.savedBlocks[query] = loader(source: source, scope: window.work.makeScope()) { source in
                    let found = await execute(source.request)
                    try Task.checkCancellation()
                    return Value(source: source, results: found)
                }
            }
            window.savedBlocks[query]?.request(source: source, isEnabled: context.isReady, reread: false)
        }
        let active = window.loader.source.query
        window.origins = window.origins.filter { wanted.contains($0.key) || $0.key == active }
    }

    private func updateBlockDemand() {
        let points = windows.values.flatMap { window -> [BlockSearchPoint] in
            let active = window.loader.source.query
            return window.origins.compactMap { query, anchor in
                query == active || window.savedBlocks[query] != nil ? anchor.point : nil
            }
        }
        blockCounts?.setDemand(Set(points))
    }

    /// One world observation updates sources even with no visible window. A window only
    /// supplies its current query; it neither builds inputs nor republishes completed hits.
    private func observeSources() {
        sourceObservation = ModelObservation(self, isActive: { !$0.isClosed }, read: {
            _ = $0.index.snapshot
            _ = $0.index.playerRoster.snapshot
            _ = $0.names.local
            _ = $0.names.online
            _ = $0.savedSearches.all
            _ = $0.singleplayerUUID()
            _ = $0.gameNames().identity
            _ = $0.blockCounts?.snapshot
            _ = $0.blockCounts?.catalog
        }) { store, _ in
            store.refresh()
        }
    }

    private func refresh() {
        guard !isClosed else { return }
        let current = Self.context(index: index, names: names, singleplayerUUID: singleplayerUUID(), gameNames: gameNames())
        if !context.hasSameInputs(as: current) { context = current }
        for query in savedSearches.all.map(\.query) where SearchQuery(query).filter != .block {
            let entry = sharedEntry(for: query)
            update(entry, query: query)
        }
        for (id, window) in windows {
            update(window, id: id, query: window.loader.source.query)
            updateSavedBlocks(window)
        }
        for (query, entry) in shared { update(entry, query: query) }
        updateBlockDemand()
    }

    private func canDisplay(_ value: Value?) -> Bool {
        guard !isClosed, let value else { return false }
        if value.blockCatalog != nil {
            guard value.blockCatalog == blockCounts?.catalog,
                  value.blockWorld == blockCounts?.snapshot.world else { return false }
        }
        return value.sources.gameNamesID == gameNames().identity && value.sources.singleplayerUUID == singleplayerUUID()
    }

    func results(for query: String) -> [SearchHit] {
        guard savedSearches.contains(query), let value = shared[query]?.loader.value, canDisplay(value) else { return [] }
        return value.hits
    }

    private var isSearchingSaved: Bool {
        !isClosed && savedSearches.all.contains {
            guard SearchQuery($0.query).filter != .block else { return false }
            guard let entry = shared[$0.query] else { return true }
            return !entry.loader.source.context.isReady || entry.loader.isReading
        }
    }

    private func wait(for entry: Shared, window: UUID, source: Source) async -> Value? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isClosed, !Task.isCancelled, windows[window] != nil,
                      entry.loader.source == source else { continuation.resume(returning: nil); return }
                if let value = entry.loader.value, value.sources == source.context.key {
                    continuation.resume(returning: value)
                } else {
                    entry.waiters[id] = Shared.Waiter(window: window, source: source, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak entry] in
                if let entry { self?.release(id, from: entry) }
            }
        }
    }

    private func release(_ id: UUID, from entry: Shared) {
        entry.waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    private func finishWaiters(in entry: Shared, value: Value) {
        for (id, waiter) in entry.waiters where waiter.source.context.key == value.sources {
            entry.waiters[id] = nil
            waiter.continuation.resume(returning: value)
        }
    }

    private func cancelWaiters(query: String, source: Source) {
        guard let entry = shared[query] else { return }
        for (id, waiter) in entry.waiters where waiter.source == source { release(id, from: entry) }
    }

    private func releaseWindow(_ id: UUID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.work.close()
        window.loader.close()
        for loader in window.savedBlocks.values { loader.close() }
        for (query, entry) in shared {
            entry.users.remove(id)
            for (waiterID, waiter) in entry.waiters where waiter.window == id { release(waiterID, from: entry) }
            update(entry, query: query)
        }
        window.shared = nil
        updateBlockDemand()
    }

    func close() {
        sourceObservation?.cancel()
        work.close()
        for window in windows.values {
            window.loader.close()
            for loader in window.savedBlocks.values { loader.close() }
        }
        for entry in shared.values {
            for waiter in entry.waiters.values { waiter.continuation.resume(returning: nil) }
            entry.waiters = [:]
            entry.loader.close()
        }
        windows = [:]
        shared = [:]
        blockCounts?.setDemand([])
    }

    func waitForTasks() async { await work.waitUntilFinished() }

    final class Handle {
        private let id: UUID
        private let window: Window
        private weak var owner: WorldQueryStore?
        var text: String {
            get { window.loader.source.query }
            set {
                owner?.update(window, id: id, query: newValue)
                owner?.updateSavedBlocks(window)
                owner?.updateBlockDemand()
            }
        }
        var isClosed: Bool { owner == nil || owner?.isClosed == true || window.loader.isClosed }
        var isActive: Bool { window.loader.source.isActive }
        var isSearching: Bool {
            !isClosed && ((isActive && (!window.loader.source.context.isReady || window.loader.isReading)) ||
                owner?.isSearchingSaved == true || window.savedBlocks.values.contains { $0.isReading } ||
                (!window.origins.isEmpty && owner?.blockCounts?.isReading == true))
        }
        var results: [SearchHit] {
            guard !isClosed, isActive, let value = window.loader.value, owner?.canDisplay(value) == true else { return [] }
            return value.hits
        }

        fileprivate init(id: UUID, window: Window, owner: WorldQueryStore) {
            self.id = id
            self.window = window
            self.owner = owner
        }

        func captureBlockOrigin(using capture: @escaping @MainActor () -> BlockSearchAnchor?) {
            guard !isClosed else { return }
            window.captureOrigin = capture
            owner?.refresh()
        }

        func results(for query: String) -> [SearchHit] {
            guard !isClosed, let owner else { return [] }
            if SearchQuery(query).filter == .block {
                guard let value = window.savedBlocks[query]?.value, owner.canDisplay(value) else { return [] }
                return value.hits
            }
            return owner.results(for: query)
        }

        func isSearchingFarther(for query: String) -> Bool {
            !isClosed && SearchQuery(query).filter == .block && window.origins[query] != nil && owner?.blockCounts?.isReading == true
        }

        func hasOreDefinitions(for query: String) -> Bool {
            SearchQuery(query).filter != .block || owner?.blockCounts?.catalog.hasOreDefinitions != false
        }

        func waitForSearch() async {
            guard let owner else { return }
            while !isClosed {
                await owner.index.waitForProjection()
                owner.refresh()
                await owner.blockCounts?.waitForCounts()
                owner.refresh()
                await window.loader.waitForCurrentRead()
                for loader in window.savedBlocks.values { await loader.waitForCurrentRead() }
                for query in owner.savedSearches.all.map(\.query) {
                    guard !isClosed, let entry = owner.shared[query] else { continue }
                    _ = await owner.wait(for: entry, window: id, source: entry.loader.source)
                }
                owner.refresh()
                if !isSearching { return }
            }
        }

        func close() {
            owner?.releaseWindow(id)
            owner = nil
        }
        func waitForTasks() async { await window.work.waitUntilFinished() }
        isolated deinit { close() }
    }
}
