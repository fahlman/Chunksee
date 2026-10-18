import ChunkseeKit
import Foundation
import Observation

/// One index pass per world, shared by every dimension's independent search controls.
@Observable
final class WorldIndexStore {
    let savedQueries = SavedQueryResults()
    private(set) var index = SearchIndex()
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var revision = 0
    private(set) var isIndexing = false
    private let readers: [RegionReader]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// A pass asked for while one runs, with the dimension to read first. It starts when the
    /// running pass ends, so a stream of world saves can't keep cancelling unfinished passes.
    @ObservationIgnored private var queuedPass: String??
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    init(readers: [RegionReader], firstDimension: String?) {
        self.readers = readers
        rebuild(firstDimension: firstDimension)
    }

    func rebuild(firstDimension: String?) {
        guard !isClosed else { return }
        if indexTask != nil {
            queuedPass = .some(firstDimension)
            return
        }
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
                self.portals = self.index.dimensions.mapValues { $0.places.compactMap(\.portal) }
                self.revision += 1
            }
            guard let self else { return }
            self.isIndexing = false
            self.indexTask = nil
            if let next = self.queuedPass {
                self.queuedPass = nil
                self.rebuild(firstDimension: next)
            }
        }
        indexTask = task
        tasks[id] = task
    }

    /// Waits for the running pass and any pass queued behind it, or until the store closes.
    func waitForIndex() async {
        while !isClosed, let task = indexTask { await task.value }
    }

    /// Closing drops the running and queued passes, so waiting for the index ends; `waitForTasks`
    /// still drains the cancelled reads.
    func cancel() {
        isClosed = true
        savedQueries.cancel()
        tasks.values.forEach { $0.cancel() }
        indexTask = nil
        queuedPass = nil
        isIndexing = false
    }

    func waitForTasks() async {
        for task in tasks.values { await task.value }
        await savedQueries.waitForTasks()
    }
}
