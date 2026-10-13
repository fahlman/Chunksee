import ChunkseeKit
import Foundation
import Observation

/// One index pass per world, shared by every dimension's independent search controls.
@Observable
final class WorldIndexStore {
    private(set) var index = SearchIndex()
    private(set) var portals: [String: [NetherPortal]] = [:]
    private(set) var revision = 0
    private(set) var isIndexing = false
    private let readers: [RegionReader]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    init(readers: [RegionReader], firstDimension: String?) {
        self.readers = readers
        rebuild(firstDimension: firstDimension)
    }

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
                self.portals = self.index.dimensions.mapValues { $0.places.compactMap(\.portal) }
                self.revision += 1
            }
            self?.isIndexing = false
        }
        indexTask = task
        tasks[id] = task
    }

    func waitForIndex() async { await indexTask?.value }

    func cancel() {
        isClosed = true
        tasks.values.forEach { $0.cancel() }
        isIndexing = false
    }

    func waitForTasks() async { for task in tasks.values { await task.value } }
}
