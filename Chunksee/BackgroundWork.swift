import Foundation

/// A world's registered work stays owned until it finishes, including after cancellation.
/// Individual consumers may cancel their own handles without closing their siblings' work.
final class BackgroundWork {
    private(set) var isClosed = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func start(priority: TaskPriority, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            defer { self?.tasks[id] = nil }
            await operation()
        }
        tasks[id] = task
        return task
    }

    func close() {
        isClosed = true
        for task in tasks.values { task.cancel() }
    }

    /// Recheck after each suspension: a running operation may have scheduled more work.
    func waitUntilFinished() async {
        while let task = tasks.values.first { await task.value }
    }
}
