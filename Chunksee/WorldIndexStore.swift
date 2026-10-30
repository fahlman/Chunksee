import ChunkseeIndex
import ChunkseeKit
import Foundation
import Observation

/// One index pass per world, shared by every dimension's independent search controls.
@Observable
final class WorldIndexStore {
    let savedQueries: SavedQueryResults
    private(set) var index = SearchIndex()
    let playerRoster: any PlayerSnapshotSource
    private(set) var playerSnapshot: PlayerSnapshot
    private var regionIndex: SearchIndex { loader.value?.index ?? SearchIndex() }
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var revision = 0
    var isIndexing: Bool { loader.isReading && loader.valueAtReadStart?.index.dimensions.isEmpty != false }
    /// The world's canonical reader catalog. Resources derive their dimension views from it.
    var readers: [RegionReader] { loader.source.readers }
    private let loader: RefreshLoader<ReaderSource, Pass, RegionSnapshot>
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var projectionRequest: (id: UUID, revision: Int, players: PlayerSnapshot)?
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var projectedRevision = 0
    private let projectCreatures: @Sendable (SearchIndex, [ShoulderPet]) async -> SearchIndex
    private let work: BackgroundWork.Scope
    private var isClosed: Bool { work.isClosed || loader.isClosed }

    /// Catalog additions belong to this same source. Each pass captures its reader array on
    /// the main actor; replacement creates a new source, retiring all previous publications.
    @MainActor @Observable private final class ReaderSource: Equatable {
        var readers: [RegionReader]
        init(_ readers: [RegionReader]) { self.readers = readers }
        nonisolated static func == (lhs: ReaderSource, rhs: ReaderSource) -> Bool { lhs === rhs }
    }

    nonisolated private struct Pass: Sendable {
        var firstDimension: String?
        /// Nil means a complete world pass. A complete request dominates queued subsets.
        var changes: [String: RegionChange]?

        mutating func merge(_ next: Pass) {
            firstDimension = next.firstDimension
            if var current = changes, let added = next.changes {
                current.merge(added) { old, new in var merged = old; merged.merge(new); return merged }
                changes = current
            } else { changes = nil }
        }
    }

    nonisolated private final class RegionSnapshot: Sendable {
        let index: SearchIndex
        init(_ index: SearchIndex) { self.index = index }
    }

    init(readers: [RegionReader], work: BackgroundWork, firstDimension: String?, playerRoster: any PlayerSnapshotSource,
         projectCreatures: @escaping @Sendable (SearchIndex, [ShoulderPet]) async -> SearchIndex = { await $0.including($1) },
         readDimension: @escaping @Sendable (RegionReader, DimensionContent?, RegionChange) async -> DimensionContent = DimensionContent.read) {
        self.work = work.makeScope()
        self.playerRoster = playerRoster
        playerSnapshot = playerRoster.snapshot
        self.projectCreatures = projectCreatures
        savedQueries = SavedQueryResults(work: work)
        loader = RefreshLoader(progressRead: { source, request, previous, publish in
            let catalog = await source.readers
            let readers = catalog.filter { request.changes?[$0.dimension.id] != nil || request.changes == nil }
                .sorted { ($0.dimension.id == request.firstDimension ? 0 : 1) < ($1.dimension.id == request.firstDimension ? 0 : 1) }
            var result = previous ?? RegionSnapshot(SearchIndex())
            for (offset, reader) in readers.enumerated() {
                try Task.checkCancellation()
                var index = result.index
                let part = await readDimension(reader, index.dimensions[reader.dimension.id], request.changes?[reader.dimension.id] ?? .all)
                try Task.checkCancellation()
                index.dimensions[reader.dimension.id] = part
                result = RegionSnapshot(index)
                if offset + 1 < readers.count, !(await publish(result)) { throw CancellationError() }
            }
            return .complete(result)
        }, work: work, priority: .utility, whenInactive: .finish, source: ReaderSource(readers),
            initialValue: RegionSnapshot(SearchIndex()),
            firstRequest: Pass(firstDimension: firstDimension, changes: nil),
            merge: { previous, next in var merged = previous; merged.merge(next); return merged })
        loader.published = { [weak self] previous, current in
            guard let self, !self.isClosed, let snapshot = current.value, previous.value !== snapshot else { return }
            self.portals = snapshot.index.dimensions.mapValues { $0.places.compactMap(\.portal) }
            self.sourceRevision += 1
            self.refreshProjection()
        }
        observePlayers()
        rebuild(firstDimension: firstDimension)
    }

    /// Index and player facts publish together after the carried-pet merge runs off-main.
    /// Views keep the previous coherent snapshot while a newer one is being prepared.
    private func observePlayers() {
        withObservationTracking { _ = playerRoster.snapshot } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.observePlayers()
                self.refreshProjection()
            }
        }
    }

    private func refreshProjection() {
        guard !isClosed else { return }
        let players = playerRoster.snapshot
        guard projectedRevision != sourceRevision || playerSnapshot !== players else { return }
        if let request = projectionRequest, request.revision == sourceRevision, request.players === players { return }
        projectionTask?.cancel()
        projectionTask = nil
        projectionRequest = nil
        let source = sourceRevision, base = regionIndex
        if players.shoulderPets.isEmpty {
            publish(base, players: players, source: source)
            return
        }
        let id = UUID(), project = projectCreatures
        projectionRequest = (id, source, players)
        projectionTask = work.start(priority: .utility) { [weak self] in
            let projected = await project(base, players.shoulderPets)
            guard let self, !Task.isCancelled, !self.isClosed,
                  self.projectionRequest?.id == id, self.sourceRevision == source,
                  self.playerRoster.snapshot === players else { return }
            self.publish(projected, players: players, source: source)
            self.projectionTask = nil
            self.projectionRequest = nil
        }
    }

    private func publish(_ projected: SearchIndex, players: PlayerSnapshot, source: Int) {
        index = projected
        playerSnapshot = players
        projectedRevision = source
        revision += 1
    }

    /// Includes a roster change whose observation callback has not run yet.
    func waitForProjection() async {
        while !isClosed {
            refreshProjection()
            guard let task = projectionTask else { return }
            await task.value
        }
    }

    /// Missing results mean loading only when an actual reader is still due to publish them.
    /// An absent/unsupported dimension cannot finish a read that was never scheduled.
    func isWaitingForPortals(in dimension: String) -> Bool {
        !isClosed && loader.isReading && portals[dimension] == nil &&
            readers.contains { $0.dimension.id == dimension }
    }

    /// A freshly validated document can discover a dimension created since the world opened.
    /// Keep existing readers, and finish a running pass before indexing the expanded catalog.
    func include(_ additions: [RegionReader], firstDimension: String?) {
        guard !isClosed else { return }
        var known = Set(readers.map { $0.dimension.id })
        let added = additions.filter { known.insert($0.dimension.id).inserted }
        guard !added.isEmpty else { return }
        loader.source.readers += added
        rebuild(firstDimension: firstDimension)
    }

    func rebuild(firstDimension: String?, changes: [String: RegionChange]? = nil) {
        guard !isClosed, changes?.isEmpty != true else { return }
        loader.request(source: loader.source, isEnabled: true,
                       refresh: Pass(firstDimension: firstDimension, changes: changes))
    }

    /// Definitions are part of the readers' immutable cache identity. Retire a previous pass
    /// immediately; ordinary region saves still use the queued-pass behavior above.
    func replace(readers: [RegionReader], firstDimension: String?) {
        replace(readers: readers, firstDimension: firstDimension, retaining: SearchIndex(), projection: SearchIndex())
    }

    /// A reread or move keeps this world's compatible completed facts while new readers check
    /// its files. Publishing an empty intermediate index would falsely remove selected items.
    func replaceWorldSource(readers: [RegionReader], firstDimension: String?) {
        let previous = Dictionary(uniqueKeysWithValues: self.readers.map { ($0.dimension.id, $0.inputs) })
        let compatible = Set(readers.filter { previous[$0.dimension.id] == $0.inputs }.map { $0.dimension.id })
        var retained = regionIndex, projected = index
        retained.dimensions = retained.dimensions.filter { compatible.contains($0.key) }
        projected.dimensions = projected.dimensions.filter { compatible.contains($0.key) }
        replace(readers: readers, firstDimension: firstDimension, retaining: retained, projection: projected)
    }

    private func replace(readers: [RegionReader], firstDimension: String?,
                         retaining retained: SearchIndex, projection: SearchIndex) {
        guard !isClosed else { return }
        projectionTask?.cancel()
        projectionTask = nil
        projectionRequest = nil
        index = projection
        revision += 1
        loader.replace(source: ReaderSource(readers), value: RegionSnapshot(retained))
        rebuild(firstDimension: firstDimension)
    }

    /// Waits for the running pass and any pass queued behind it, or until the store closes.
    func waitForIndex() async {
        while !isClosed {
            await loader.waitForCurrentRead()
            await waitForProjection()
            if !loader.isReading { return }
        }
    }

    /// Closing drops the running and queued passes, so waiting for the index ends; `waitForTasks`
    /// still drains the cancelled reads.
    func cancel() {
        loader.close()
        work.close()
        savedQueries.cancel()
        projectionTask = nil
        projectionRequest = nil
    }

    func waitForTasks() async {
        await loader.waitUntilFinished()
        await work.waitUntilFinished()
        await savedQueries.waitForTasks()
    }
}
