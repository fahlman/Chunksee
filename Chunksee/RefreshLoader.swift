import Observation

/// Retains a value while it reloads and folds changes during a read into one following pass.
/// Waiting callers do not own the read; only this loader or its world may cancel it.
@Observable
final class RefreshLoader<Value: Sendable> {
    private(set) var value: Value?
    private(set) var isClosed = false
    private let work: BackgroundWork
    private let priority: TaskPriority
    private let read: @Sendable (Value?) async -> Value
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var invalidated = false

    init(work: BackgroundWork, priority: TaskPriority, read: @escaping @Sendable (Value?) async -> Value) {
        self.work = work
        self.priority = priority
        self.read = read
    }

    func request(isEnabled: Bool, reread: Bool) {
        guard !isClosed, !work.isClosed else { return }
        self.isEnabled = isEnabled
        if reread { invalidated = true }
        guard isEnabled, task == nil, invalidated || value == nil else { return }
        invalidated = false
        let read = read, work = work
        task = work.start(priority: priority) { [weak self] in
            defer { self?.task = nil }
            guard !Task.isCancelled, !work.isClosed else { return }
            repeat {
                let value = await read(self?.value)
                guard let self, !Task.isCancelled, !self.isClosed, !work.isClosed else { return }
                self.value = value
                guard self.isEnabled, self.invalidated else { return }
                self.invalidated = false
            } while true
        }
    }

    func close() {
        isClosed = true
        invalidated = false
        task?.cancel()
    }

    func waitUntilFinished() async {
        while let task { await task.value }
    }
}
