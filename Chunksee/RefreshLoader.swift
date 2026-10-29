import Foundation
import Observation

/// Heat-map progress may finish after hiding; optional metadata stops when nobody needs it.
nonisolated enum InactiveReadPolicy: Equatable, Sendable {
    case finish, cancel
}

/// Retains a value while it reloads and folds changes during a read into one following pass.
/// Waiting callers do not own the read; only this loader or its world may cancel it.
@Observable
final class RefreshLoader<Source: Equatable & Sendable, Value: Sendable> {
    private(set) var value: Value?
    private(set) var isClosed = false
    private(set) var source: Source
    let work: BackgroundWork.Scope
    private let priority: TaskPriority?
    private let whenInactive: InactiveReadPolicy
    private let read: @Sendable (Source, Value?) async throws -> Value
    @ObservationIgnored private var active: UUID?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var invalidated = false

    init(work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
         read: @escaping @Sendable (Source, Value?) async throws -> Value) {
        self.work = work.makeScope()
        self.priority = priority
        self.whenInactive = whenInactive
        self.source = source
        self.read = read
    }

    func request(source: Source, isEnabled: Bool, reread: Bool) {
        guard !isClosed, !work.isClosed else { return }
        if self.source != source {
            work.cancel()
            active = nil
            self.source = source
            value = nil
            invalidated = true
        }
        self.isEnabled = isEnabled
        if reread { invalidated = true }
        if !isEnabled, whenInactive == .cancel, active != nil {
            work.cancel()
            active = nil
            invalidated = true
        }
        guard isEnabled, active == nil, invalidated || value == nil else { return }
        invalidated = false
        let read = read, work = work, id = UUID()
        guard work.start(priority: priority, operation: { [weak self] in
            defer { if self?.active == id { self?.active = nil } }
            repeat {
                guard !Task.isCancelled, !work.isClosed else { return }
                let updated: Value?
                do { updated = try await read(source, self?.value) }
                catch { updated = nil }
                guard let self, !Task.isCancelled, !self.isClosed, !work.isClosed,
                      self.active == id else { return }
                // Failure preserves this source's last coherent value. An empty successful
                // value is still a publication, so removals do not leave old facts behind.
                if let updated { self.value = updated }
                // Publication can synchronously notify observers. A replacement or closure
                // during that callback must not let this read edit the new request's state.
                guard self.active == id, !self.isClosed, !work.isClosed else { return }
                let requestedAgain = self.invalidated
                // Failed reads retry on the next request, never in a failure loop.
                if case nil = updated { self.invalidated = true }
                guard self.isEnabled, requestedAgain else { return }
                self.invalidated = false
            } while true
        }) != nil else { return }
        active = id
    }

    func close() {
        isClosed = true
        invalidated = false
        work.close()
    }

    func waitUntilFinished() async {
        await work.waitUntilFinished()
    }
}
