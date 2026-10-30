import Foundation

/// Related work owned by a world or an app-wide source, such as player names.
/// Registered work stays owned until it finishes, including after cancellation.
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

    /// A source's access must outlive its accepted work, but must not wait for the next source.
    /// Capture before replacing inputs; register the drain before observers can close the world.
    func afterCurrentWork(_ completion: @escaping @MainActor () -> Void) {
        let retiring = tasks.values.map(\.task)
        start(priority: .utility) {
            for task in retiring { await task.value }
            completion()
        }
    }

    /// Recheck after each suspension: a running operation may have scheduled more work.
    func waitUntilFinished() async {
        while let task = tasks.values.first?.task { await task.value }
    }

    /// Drains a consumer's related scopes together, including work added to an earlier scope
    /// while another finishes. Scopes must belong to this owner.
    func waitUntilFinished(in scopes: [Scope]) async {
        precondition(scopes.allSatisfy { $0.owner === self })
        await waitUntilFinished(inIDs: Set(scopes.map(\.id)))
    }

    private func cancel(in scope: UUID) {
        for entry in tasks.values where entry.scope == scope { entry.task.cancel() }
    }

    private func waitUntilFinished(in scope: UUID) async {
        await waitUntilFinished(inIDs: [scope])
    }

    private func waitUntilFinished(inIDs scopes: Set<UUID>) async {
        while let task = tasks.values.first(where: { $0.scope.map(scopes.contains) == true })?.task { await task.value }
    }

    /// One consumer's task group. Canceled/replaced reads remain in the owner's registry
    /// until they finish, while a local drain never waits for another consumer's work.
    final class Scope {
        fileprivate let owner: BackgroundWork
        fileprivate let id = UUID()
        private var closed = false
        var isClosed: Bool { closed || owner.isClosed }
        var unfinishedCount: Int { owner.tasks.values.reduce(0) { $0 + ($1.scope == id ? 1 : 0) } }

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
