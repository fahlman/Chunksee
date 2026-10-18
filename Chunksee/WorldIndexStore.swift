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
    /// The world's canonical reader catalog. Resources derive their dimension views from it.
    private(set) var readers: [RegionReader]
    private let readDimension: @Sendable (RegionReader, DimensionIndex?, RegionChange) async -> DimensionIndex
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// A pass asked for while one runs, with the dimension to read first. It starts when the
    /// running pass ends, so a stream of world saves can't keep cancelling unfinished passes.
    @ObservationIgnored private var queuedPass: Pass?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

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

    init(readers: [RegionReader], firstDimension: String?,
         readDimension: @escaping @Sendable (RegionReader, DimensionIndex?, RegionChange) async -> DimensionIndex = DimensionIndex.read) {
        self.readers = readers
        self.readDimension = readDimension
        rebuild(firstDimension: firstDimension)
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
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            defer { self?.tasks[id] = nil }
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
        tasks.values.forEach { $0.cancel() }
        indexTask = nil
        queuedPass = nil
        isIndexing = false
    }

    func waitForTasks() async { for task in tasks.values { await task.value } }
}
