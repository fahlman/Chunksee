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
    private var regionIndex = SearchIndex()
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var revision = 0
    private(set) var isIndexing = false
    /// The world's canonical reader catalog. Resources derive their dimension views from it.
    private(set) var readers: [RegionReader]
    private let readDimension: @Sendable (RegionReader, DimensionContent?, RegionChange) async -> DimensionContent
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var readerGeneration = 0
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var projectionRequest: (id: UUID, revision: Int, players: PlayerSnapshot)?
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var projectedRevision = 0
    private let projectCreatures: @Sendable (SearchIndex, [ShoulderPet]) async -> SearchIndex
    /// A pass asked for while one runs, with the dimension to read first. It starts when the
    /// running pass ends, so a stream of world saves can't keep cancelling unfinished passes.
    @ObservationIgnored private var queuedPass: Pass?
    private let work: BackgroundWork.Scope
    private var isClosed: Bool { work.isClosed }

    private struct Pass {
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

    init(readers: [RegionReader], work: BackgroundWork, firstDimension: String?, playerRoster: any PlayerSnapshotSource,
         projectCreatures: @escaping @Sendable (SearchIndex, [ShoulderPet]) async -> SearchIndex = { await $0.including($1) },
         readDimension: @escaping @Sendable (RegionReader, DimensionContent?, RegionChange) async -> DimensionContent = DimensionContent.read) {
        self.work = work.makeScope()
        self.playerRoster = playerRoster
        playerSnapshot = playerRoster.snapshot
        self.projectCreatures = projectCreatures
        savedQueries = SavedQueryResults(work: work)
        self.readers = readers
        self.readDimension = readDimension
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
        !isClosed && indexTask != nil && portals[dimension] == nil &&
            readers.contains { $0.dimension.id == dimension }
    }

    /// A freshly validated document can discover a dimension created since the world opened.
    /// Keep existing readers, and finish a running pass before indexing the expanded catalog.
    func include(_ additions: [RegionReader], firstDimension: String?) {
        guard !isClosed else { return }
        var known = Set(readers.map { $0.dimension.id })
        let added = additions.filter { known.insert($0.dimension.id).inserted }
        guard !added.isEmpty else { return }
        readers += added
        rebuild(firstDimension: firstDimension)
    }

    func rebuild(firstDimension: String?, changes: [String: RegionChange]? = nil) {
        guard !isClosed, changes?.isEmpty != true else { return }
        let pass = Pass(firstDimension: firstDimension, changes: changes)
        if indexTask != nil {
            if queuedPass != nil { queuedPass?.merge(pass) }
            else { queuedPass = pass }
            return
        }
        isIndexing = index.dimensions.isEmpty
        let readers = readers.filter { changes?[$0.dimension.id] != nil || changes == nil }
            .sorted { ($0.dimension.id == firstDimension ? 0 : 1) < ($1.dimension.id == firstDimension ? 0 : 1) }
        let readDimension = readDimension, generation = readerGeneration
        indexTask = work.start(priority: .utility) { [weak self] in
            defer {
                if self?.isClosed == true, self?.readerGeneration == generation {
                    self?.indexTask = nil
                    self?.queuedPass = nil
                    self?.isIndexing = false
                }
            }
            for reader in readers {
                guard !Task.isCancelled, self?.isClosed == false else { return }
                let previous = self?.regionIndex.dimensions[reader.dimension.id]
                let part = await readDimension(reader, previous, changes?[reader.dimension.id] ?? .all)
                guard let self, !Task.isCancelled, !self.isClosed, self.readerGeneration == generation else { return }
                self.regionIndex.dimensions[reader.dimension.id] = part
                self.portals = self.regionIndex.dimensions.mapValues { $0.places.compactMap(\.portal) }
                self.sourceRevision += 1
                self.refreshProjection()
            }
            guard let self, !Task.isCancelled, !self.isClosed, self.readerGeneration == generation else { return }
            self.isIndexing = false
            self.indexTask = nil
            if let next = self.queuedPass {
                self.queuedPass = nil
                self.rebuild(firstDimension: next.firstDimension, changes: next.changes)
            }
        }
    }

    /// Definitions are part of the readers' immutable cache identity. Retire a previous pass
    /// immediately; ordinary region saves still use the queued-pass behavior above.
    func replace(readers: [RegionReader], firstDimension: String?) {
        guard !isClosed else { return }
        readerGeneration += 1
        indexTask?.cancel()
        indexTask = nil
        queuedPass = nil
        self.readers = readers
        regionIndex = SearchIndex()
        index = SearchIndex()
        portals = [:]
        sourceRevision += 1
        projectionTask?.cancel()
        projectionTask = nil
        projectionRequest = nil
        revision += 1
        refreshProjection()
        rebuild(firstDimension: firstDimension)
    }

    /// Waits for the running pass and any pass queued behind it, or until the store closes.
    func waitForIndex() async {
        while !isClosed {
            if let task = indexTask { await task.value; continue }
            await waitForProjection()
            if indexTask == nil { return }
        }
    }

    /// Closing drops the running and queued passes, so waiting for the index ends; `waitForTasks`
    /// still drains the cancelled reads.
    func cancel() {
        work.close()
        savedQueries.cancel()
        projectionTask = nil
        projectionRequest = nil
        indexTask = nil
        queuedPass = nil
        isIndexing = false
    }

    func waitForTasks() async {
        await work.waitUntilFinished()
        await savedQueries.waitForTasks()
    }
}
