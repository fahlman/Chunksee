import Foundation
import ChunkseeKit

/// A publication's identity represents its immutable player data; names can change separately.
nonisolated struct SearchSources: Equatable, Sendable {
    var names: [UUID: PlayerPresentation.Name]
    var playerSnapshot: PlayerSnapshot
    var indexRevision: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.indexRevision == rhs.indexRevision && lhs.playerSnapshot === rhs.playerSnapshot && lhs.names == rhs.names
    }
}

/// One world's saved-query work. A window can stop waiting without cancelling its siblings.
/// Only saved queries stay cached; retired sources drain after their last waiter leaves.
final class SavedQueryResults {
    typealias Results = [String: [SearchHit]]
    private struct Entry {
        var query: String
        var sources: SearchSources
        var task: Task<Void, Never>?
        var results: Results?
        var waiters: [UUID: CheckedContinuation<Results?, Never>] = [:]
    }

    private var entries: [UUID: Entry] = [:]
    private var current: [String: UUID] = [:]
    private var waiting: [UUID: UUID] = [:]
    private let work: BackgroundWork.Scope
    private var isClosed: Bool { work.isClosed }

    init(work: BackgroundWork) { self.work = work.makeScope() }

    func keep(_ queries: Set<String>) {
        guard !isClosed else { return }
        for (query, id) in current where !queries.contains(query) {
            current[query] = nil
            retire(id)
        }
    }

    func results(for request: SearchRequest, sources: SearchSources, waiter: UUID,
                 execute: @escaping @Sendable (SearchRequest) async -> Results) async -> Results? {
        guard !isClosed, !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isClosed, !Task.isCancelled else { continuation.resume(returning: nil); return }
                let query = request.queries[0]
                let id: UUID
                if let existing = current[query], entries[existing]?.sources == sources {
                    id = existing
                } else {
                    id = UUID()
                    guard let task = work.start(priority: .userInitiated, operation: { [weak self] in
                        let found = await execute(request)
                        self?.finish(id, with: Task.isCancelled ? nil : found)
                    }) else { continuation.resume(returning: nil); return }
                    let previous = current.updateValue(id, forKey: query)
                    entries[id] = Entry(query: query, sources: sources, task: task)
                    if let previous { retire(previous) }
                }
                if let found = entries[id]?.results {
                    continuation.resume(returning: found)
                } else {
                    entries[id]?.waiters[waiter] = continuation
                    waiting[waiter] = id
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(waiter) }
        }
    }

    /// Also called synchronously when a document replaces a query or closes.
    func release(_ waiter: UUID) {
        guard let id = waiting.removeValue(forKey: waiter),
              let continuation = entries[id]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        retire(id)
    }

    private func retire(_ id: UUID) {
        guard let entry = entries[id], current[entry.query] != id, entry.waiters.isEmpty else { return }
        entry.task?.cancel()
        entries[id] = nil
        // The shared scope keeps the canceled task until its read returns.
    }

    private func finish(_ id: UUID, with results: Results?) {
        guard !isClosed else { cancel(); return }
        guard var entry = entries[id] else { return }
        entry.task = nil
        let waiters = entry.waiters
        entry.waiters = [:]
        entry.results = results
        entries[id] = entry
        for (waiter, continuation) in waiters {
            waiting[waiter] = nil
            continuation.resume(returning: results)
        }
        retire(id)
    }

    func cancel() {
        work.close()
        for entry in entries.values {
            for continuation in entry.waiters.values { continuation.resume(returning: nil) }
        }
        entries = [:]
        current = [:]
        waiting = [:]
    }

    func waitForTasks() async { await work.waitUntilFinished() }
}
