import Foundation

/// A world's registered work stays owned until it finishes, including after cancellation.
/// Individual consumers may cancel their own handles without closing their siblings' work.
final class BackgroundWork {
    private(set) var isClosed = false
    private struct Entry {
        let scope: UUID?
        let task: Task<Void, Never>
    }
    private var tasks: [UUID: Entry] = [:]

    func makeScope() -> Scope { Scope(owner: self) }

    @discardableResult
    func start(priority: TaskPriority?, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        start(in: nil, priority: priority, operation: operation)
    }

    private func start(in scope: UUID?, priority: TaskPriority?,
                       operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            defer { self?.tasks[id] = nil }
            await operation()
        }
        tasks[id] = Entry(scope: scope, task: task)
        return task
    }

    func close() {
        isClosed = true
        for entry in tasks.values { entry.task.cancel() }
    }

    /// Recheck after each suspension: a running operation may have scheduled more work.
    func waitUntilFinished() async {
        while let task = tasks.values.first?.task { await task.value }
    }

    private func cancel(in scope: UUID) {
        for entry in tasks.values where entry.scope == scope { entry.task.cancel() }
    }

    private func waitUntilFinished(in scope: UUID) async {
        while let task = tasks.values.first(where: { $0.scope == scope })?.task { await task.value }
    }

    /// One consumer's task group. Canceled/replaced reads remain in the world's registry
    /// until they finish, while a local drain never waits for another consumer's work.
    final class Scope {
        private let owner: BackgroundWork
        private let id = UUID()
        private var closed = false
        var isClosed: Bool { closed || owner.isClosed }

        fileprivate init(owner: BackgroundWork) { self.owner = owner }

        @discardableResult
        func start(priority: TaskPriority?, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
            guard !isClosed else { return nil }
            return owner.start(in: id, priority: priority, operation: operation)
        }

        func cancel() { owner.cancel(in: id) }
        func close() {
            guard !closed else { return }
            closed = true
            cancel()
        }
        func waitUntilFinished() async { await owner.waitUntilFinished(in: id) }

        isolated deinit { close() }
    }
}
