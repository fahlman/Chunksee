import ChunkseeKit
import Foundation
import Observation

/// One index pass per world, shared by every dimension's independent search controls.
@Observable
final class WorldIndexStore {
    let savedQueries: SavedQueryResults
    private(set) var index = SearchIndex()
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var revision = 0
    private(set) var isIndexing = false
    /// The world's canonical reader catalog. Resources derive their dimension views from it.
    private(set) var readers: [RegionReader]
    private let readDimension: @Sendable (RegionReader, DimensionIndex?, RegionChange) async -> DimensionIndex
    @ObservationIgnored private var indexTask: Task<Void, Never>?
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

    init(readers: [RegionReader], work: BackgroundWork, firstDimension: String?,
         readDimension: @escaping @Sendable (RegionReader, DimensionIndex?, RegionChange) async -> DimensionIndex = DimensionIndex.read) {
        self.work = work.makeScope()
        savedQueries = SavedQueryResults(work: work)
        self.readers = readers
        self.readDimension = readDimension
        rebuild(firstDimension: firstDimension)
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
        let readDimension = readDimension
        indexTask = work.start(priority: .utility) { [weak self] in
            defer {
                if self?.isClosed == true {
                    self?.indexTask = nil
                    self?.queuedPass = nil
                    self?.isIndexing = false
                }
            }
            for reader in readers {
                guard !Task.isCancelled, self?.isClosed == false else { return }
                let previous = self?.index.dimensions[reader.dimension.id]
                let part = await readDimension(reader, previous, changes?[reader.dimension.id] ?? .all)
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                self.index.dimensions[reader.dimension.id] = part
                self.portals = self.index.dimensions.mapValues { $0.places.compactMap(\.portal) }
                self.revision += 1
            }
            guard let self else { return }
            self.isIndexing = false
            self.indexTask = nil
            if let next = self.queuedPass {
                self.queuedPass = nil
                self.rebuild(firstDimension: next.firstDimension, changes: next.changes)
            }
        }
    }

    /// Waits for the running pass and any pass queued behind it, or until the store closes.
    func waitForIndex() async {
        while !isClosed, let task = indexTask { await task.value }
    }

    /// Closing drops the running and queued passes, so waiting for the index ends; `waitForTasks`
    /// still drains the cancelled reads.
    func cancel() {
        work.close()
        savedQueries.cancel()
        indexTask = nil
        queuedPass = nil
        isIndexing = false
    }

    func waitForTasks() async {
        await work.waitUntilFinished()
        await savedQueries.waitForTasks()
    }
}
