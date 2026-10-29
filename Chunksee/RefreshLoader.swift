import Foundation
import Observation

/// Heat-map progress may finish after hiding; optional metadata stops when nobody needs it.
nonisolated enum InactiveReadPolicy: Equatable, Sendable {
    case finish, cancel
}

/// Producers without distinct request strengths need only one kind of invalidation.
nonisolated enum RefreshInvalidation: Sendable { case refresh }

/// Retains a value while it reloads and folds changes during a read into one following pass.
/// Waiting callers do not own the read; only this loader or its world may cancel it.
@Observable
final class RefreshLoader<Source: Equatable & Sendable, Request: Sendable, Value: Sendable> {
    private var publication: (source: Source, value: Value?)
    var value: Value? { publication.value }
    var source: Source { publication.source }
    private(set) var isClosed = false
    let work: BackgroundWork.Scope
    private let priority: TaskPriority?
    private let whenInactive: InactiveReadPolicy
    private let firstRequest: Request
    private let merge: @Sendable (Request, Request) -> Request
    private let retainingValue: @Sendable (Value, Source, Source) -> Value?
    private let read: @Sendable (Source, Request, Value?) async throws -> Value
    @ObservationIgnored private var active: (id: UUID, request: Request)?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var retry: Request?

    init(work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
         initialValue: Value? = nil,
         firstRequest: Request, merge: @escaping @Sendable (Request, Request) -> Request,
         retainingValue: @escaping @Sendable (Value, Source, Source) -> Value? = { _, _, _ in nil },
         read: @escaping @Sendable (Source, Request, Value?) async throws -> Value) {
        self.work = work.makeScope()
        self.priority = priority
        self.whenInactive = whenInactive
        publication = (source, initialValue)
        self.firstRequest = firstRequest
        self.merge = merge
        self.retainingValue = retainingValue
        self.read = read
    }

    func request(source: Source, isEnabled: Bool, refresh: Request?) {
        guard !isClosed, !work.isClosed else { return }
        let replaced = self.source != source
        let retained = replaced ? value.flatMap { retainingValue($0, self.source, source) } : nil
        if replaced {
            work.cancel()
            active = nil
            pending = firstRequest
            retry = nil
        }
        self.isEnabled = isEnabled
        if let refresh { pending = merged(pending, refresh) }
        if replaced {
            // Publish source and its compatible value together. Observers may synchronously
            // request another source; only their current demand may run after this callback.
            publication = (source, retained)
            guard !self.isClosed, !work.isClosed, self.source == source else { return }
        }
        if !self.isEnabled, whenInactive == .cancel, let active {
            retry = merged(retry, active.request)
            work.cancel()
            self.active = nil
        }
        guard self.isEnabled, active == nil, let request = takeRequest() else { return }
        let read = read, work = work, source = self.source, id = UUID()
        guard work.start(priority: priority, operation: { [weak self] in
            defer { if self?.active?.id == id { self?.active = nil } }
            var request = request
            repeat {
                guard !Task.isCancelled, !work.isClosed else { return }
                let updated: Value?
                do { updated = try await read(source, request, self?.value) }
                catch { updated = nil }
                guard let self, !Task.isCancelled, !self.isClosed, !work.isClosed,
                      self.active?.id == id else { return }
                // Failure preserves this source's last coherent value. An empty successful
                // value is still a publication, so removals do not leave old facts behind.
                if let updated { self.publication = (source, updated) }
                // Publication can synchronously notify observers. A replacement or closure
                // during that callback must not let this read edit the new request's state.
                guard self.active?.id == id, !self.isClosed, !work.isClosed else { return }
                // Preserve failed request strength, but only external demand starts another
                // pass. A failed forced read must not become a weaker metadata-only retry.
                if case nil = updated { self.retry = self.merged(self.retry, request) }
                guard self.isEnabled, self.pending != nil, let next = self.takeRequest() else { return }
                request = next
                self.active = (id, request)
            } while true
        }) != nil else { return }
        active = (id, request)
    }

    private func merged(_ previous: Request?, _ request: Request) -> Request {
        previous.map { merge($0, request) } ?? request
    }

    private func takeRequest() -> Request? {
        let request = pending.map { merged(retry, $0) } ?? retry ?? (value == nil ? firstRequest : nil)
        pending = nil
        retry = nil
        return request
    }

    func close() {
        isClosed = true
        pending = nil
        retry = nil
        work.close()
        publication = (source, nil)
    }

    func waitUntilFinished() async {
        await work.waitUntilFinished()
    }
}

extension RefreshLoader where Request == RefreshInvalidation {
    convenience init(work: BackgroundWork, priority: TaskPriority?, whenInactive: InactiveReadPolicy, source: Source,
                     initialValue: Value? = nil,
                     read: @escaping @Sendable (Source, Value?) async throws -> Value) {
        self.init(work: work, priority: priority, whenInactive: whenInactive, source: source,
                  initialValue: initialValue,
                  firstRequest: .refresh, merge: { _, _ in .refresh }) { source, _, previous in
            try await read(source, previous)
        }
    }

    func request(source: Source, isEnabled: Bool, reread: Bool) {
        request(source: source, isEnabled: isEnabled, refresh: reread ? .refresh : nil)
    }
}
